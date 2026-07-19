import Foundation
import ObjectiveC.runtime
import MediaRemoteAdapter

/// Owns the `perl run.pl <dylib> loop` process from the `MediaRemoteAdapter`
/// SPM package and streams decoded `TrackInfo` values.
///
/// Why not `MediaController` from the package directly? Its dylib lookup uses
/// `Bundle(for: MediaController.self).executablePath`, which is only non-nil when
/// Xcode wraps the product as a `.framework`. In a bare-SPM build (both
/// `.build/debug` and a `dist/Atoll.app` with the dylib in
/// `Contents/Frameworks`) that call returns nil and `MediaController` hits an
/// `assertionFailure` (crashing debug builds). We therefore resolve the loaded
/// dylib path robustly via `class_getImageName` and drive the exact same perl
/// script + stdin command protocol ourselves, while reusing the package's
/// `TrackInfo` Codable model for parsing.
final class MediaAdapterTransport {

    /// Called on the main queue with each decoded update; nil = no active player.
    var onTrackInfo: ((TrackInfo?) -> Void)?
    /// Called on the main queue when the loop process exits (crash or system kill).
    var onTerminated: (() -> Void)?

    private var process: Process?
    private var stdinPipe: Pipe?
    private let commandQueue = DispatchQueue(label: "atoll.media.adapter.commands")
    private var intentionalStop = false

    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    init() {
        _ = MediaAdapterTransport.ignoreSigpipe
    }

    // MARK: - Path resolution

    /// Absolute path of libMediaRemoteAdapter.dylib as actually loaded by dyld.
    /// Works in every layout: `.build/<config>/`, `Contents/Frameworks/`, or an
    /// Xcode-style framework wrapper.
    static let dylibPath: String? = {
        guard let cPath = class_getImageName(MediaController.self) else { return nil }
        let path = String(cString: cPath)
        // If the product were ever statically linked this would be the app binary;
        // perl can dlopen that too (the adapter symbols would live inside it).
        return path
    }()

    /// Absolute path of the package's `run.pl`, searched across known layouts.
    static let runScriptPath: String? = {
        let fm = FileManager.default
        let bundleName = "MediaRemoteAdapter_MediaRemoteAdapter.bundle"
        var directories: [URL] = []
        if let res = Bundle.main.resourceURL {
            directories.append(res) // Atoll.app/Contents/Resources
        }
        if let dylib = dylibPath {
            let dylibDir = URL(fileURLWithPath: dylib).deletingLastPathComponent()
            directories.append(dylibDir) // .build/<config>/ (dev runs)
            directories.append(
                dylibDir.deletingLastPathComponent().appendingPathComponent("Resources")
            ) // Contents/Frameworks -> Contents/Resources
        }
        let relativeCandidates = [
            "\(bundleName)/run.pl",
            "\(bundleName)/Contents/Resources/run.pl",
            "run.pl",
        ]
        for dir in directories {
            for rel in relativeCandidates {
                let candidate = dir.appendingPathComponent(rel).path
                if fm.fileExists(atPath: candidate) { return candidate }
            }
        }
        return nil
    }()

    /// True when both the dylib and the perl script could be located.
    static var isAvailable: Bool { dylibPath != nil && runScriptPath != nil }

    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Streaming

    func start() {
        guard process == nil else { return }
        guard let script = MediaAdapterTransport.runScriptPath,
              let dylib = MediaAdapterTransport.dylibPath else {
            NSLog("Atoll/Media: MediaRemote adapter resources not found (script or dylib missing)")
            return
        }

        intentionalStop = false

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = [script, dylib, "loop"]

        let input = Pipe()
        let output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = FileHandle.nullDevice

        // The buffer is closure-local: handler invocations are serialized on the
        // FileHandle's internal queue and each launch gets a fresh buffer, so
        // start()/stop() on the main thread never race it.
        var lineBuffer = Data()
        output.fileHandleForReading.readabilityHandler = { [weak self, weak proc] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            lineBuffer.append(data)
            let newline = UInt8(ascii: "\n")
            while let idx = lineBuffer.firstIndex(of: newline) {
                let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<idx)
                lineBuffer.removeSubrange(lineBuffer.startIndex...idx)
                DispatchQueue.main.async { [weak self, weak proc] in
                    guard let self, let proc, self.process === proc else { return }
                    self.handleLine(lineData)
                }
            }
        }

        proc.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.process === finished else { return }
                self.process = nil
                self.stdinPipe = nil
                if !self.intentionalStop {
                    self.onTerminated?()
                }
            }
        }

        do {
            try proc.run()
            process = proc
            stdinPipe = input
        } catch {
            NSLog("Atoll/Media: failed to launch adapter loop: \(error)")
            process = nil
            stdinPipe = nil
        }
    }

    func stop() {
        intentionalStop = true
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdinPipe = nil
    }

    /// Always called on the main queue, only for the current process' output.
    private func handleLine(_ lineData: Data) {
        guard !lineData.isEmpty else { return }
        if lineData == Data("NIL".utf8) {
            onTrackInfo?(nil)
            return
        }
        if let info = try? JSONDecoder().decode(TrackInfo.self, from: lineData) {
            onTrackInfo?(info)
        }
        // Non-JSON diagnostics on stdout are ignored.
    }

    // MARK: - Commands

    /// Sends an inline command over the loop process' stdin; falls back to a
    /// one-shot perl invocation when the loop is not running.
    /// Known commands: play, pause, toggle_play_pause, next_track, previous_track,
    /// stop, "set_time <seconds>", "set_shuffle_mode <0|1|2>", "set_repeat_mode <0|1|2>".
    func send(_ command: String) {
        guard let data = (command + "\n").data(using: .utf8) else { return }
        let proc = process
        let pipe = stdinPipe
        commandQueue.async { [weak self] in
            if let proc, proc.isRunning, let pipe {
                do {
                    try pipe.fileHandleForWriting.write(contentsOf: data)
                    return
                } catch {
                    // Pipe closed under us — fall through to one-shot.
                }
            }
            self?.sendOneShot(command)
        }
    }

    private func sendOneShot(_ command: String) {
        guard let script = MediaAdapterTransport.runScriptPath,
              let dylib = MediaAdapterTransport.dylibPath else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = [script, dylib] + command.split(separator: " ").map(String.init)
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            NSLog("Atoll/Media: one-shot adapter command failed: \(error)")
        }
    }
}

// MARK: - TrackInfo mapping

extension MediaPlaybackState {
    /// Maps the adapter payload into the app-level model.
    init(payload: TrackInfo.Payload) {
        let playing = payload.isPlaying ?? false
        self.init(
            title: payload.title ?? "",
            artist: payload.artist ?? "",
            album: payload.album ?? "",
            artworkImage: payload.artwork,
            bundleIdentifier: payload.bundleIdentifier,
            appName: payload.applicationName,
            isPlaying: playing,
            duration: (payload.durationMicros ?? 0) / 1_000_000,
            elapsed: (payload.elapsedTimeMicros ?? 0) / 1_000_000,
            timestamp: payload.timestampEpochMicros
                .map { Date(timeIntervalSince1970: $0 / 1_000_000) } ?? Date(),
            playbackRate: payload.playbackRate ?? (playing ? 1 : 0),
            shuffleMode: payload.shuffleMode
                .flatMap { ShuffleMode(rawValue: $0.rawValue) } ?? .off,
            repeatMode: payload.repeatMode
                .flatMap { RepeatMode(rawValue: $0.rawValue) } ?? .off
        )
    }
}
