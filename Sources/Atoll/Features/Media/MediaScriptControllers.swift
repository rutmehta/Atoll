import AppKit
import Foundation

/// AppleScript-based now-playing fallback for Spotify and Apple Music.
/// Used when the MediaRemote adapter yields nothing (unbundled resources or a
/// future macOS breaking the perl loophole) while one of these players runs.
///
/// Requires `NSAppleEventsUsageDescription` in Info.plist; macOS asks the user
/// for per-app Automation consent on first use. Denial is surfaced via
/// `onPermissionDenied` (never crashes).
@MainActor
final class MediaScriptPlayerController {

    enum PlayerApp: String, CaseIterable {
        case spotify
        case appleMusic

        var bundleIdentifier: String {
            switch self {
            case .spotify: return "com.spotify.client"
            case .appleMusic: return "com.apple.Music"
            }
        }

        /// Name used inside `tell application "..."`.
        var scriptTarget: String {
            switch self {
            case .spotify: return "Spotify"
            case .appleMusic: return "Music"
            }
        }

        var displayName: String {
            switch self {
            case .spotify: return "Spotify"
            case .appleMusic: return "Apple Music"
            }
        }

        /// DistributedNotificationCenter name fired on playback changes (no TCC needed).
        var playbackNotification: Notification.Name {
            switch self {
            case .spotify: return Notification.Name("com.spotify.client.PlaybackStateChanged")
            case .appleMusic: return Notification.Name("com.apple.Music.playerInfo")
            }
        }

        var isRunning: Bool {
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
        }
    }

    /// Called on the main actor with a merged state (nil = nothing playing).
    var onStateChanged: ((MediaPlaybackState?) -> Void)?
    /// Fired once when Automation permission is denied (error -1743).
    var onPermissionDenied: (() -> Void)?
    /// Restrict polling/controls to a single player (from the settings picker).
    var restriction: PlayerApp?

    private(set) var activePlayer: PlayerApp?
    private(set) var isActive = false

    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var scriptCache: [String: NSAppleScript] = [:]
    private var reportedPermissionDenial = false

    private var artworkIdentity: String?
    private var artworkImage: NSImage?
    private var artworkFetchInFlight = false

    // MARK: Lifecycle

    func start() {
        guard !isActive else { return }
        isActive = true

        let center = DistributedNotificationCenter.default()
        for app in PlayerApp.allCases {
            let token = center.addObserver(
                forName: app.playbackNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            observers.append(token)
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        pollTimer?.tolerance = 0.5
        refresh()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        let center = DistributedNotificationCenter.default()
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        activePlayer = nil
        artworkIdentity = nil
        artworkImage = nil
    }

    // MARK: State polling

    func refresh() {
        guard isActive else { return }
        let candidates: [PlayerApp] = restriction.map { [$0] } ?? PlayerApp.allCases
        let running = candidates.filter(\.isRunning)
        guard !running.isEmpty else {
            activePlayer = nil
            onStateChanged?(nil)
            return
        }

        var states: [(PlayerApp, MediaPlaybackState)] = []
        for app in running {
            if let state = fetchState(from: app) {
                states.append((app, state))
            }
        }

        // Prefer the player that is actually playing, then the sticky active
        // player, then anything with a loaded track.
        let chosen = states.first(where: { $0.1.isPlaying })
            ?? states.first(where: { $0.0 == activePlayer })
            ?? states.first

        guard let (app, state) = chosen else {
            activePlayer = nil
            onStateChanged?(nil)
            return
        }
        activePlayer = app
        deliver(state, from: app)
    }

    private func deliver(_ state: MediaPlaybackState, from app: PlayerApp) {
        var merged = state
        let needsArtwork = artworkIdentity != merged.trackIdentity
        merged.artworkImage = needsArtwork ? nil : artworkImage
        // Publish first: the Apple Music artwork script runs synchronously and
        // re-enters refresh() via storeArtwork once the image is decoded.
        onStateChanged?(merged)
        if needsArtwork {
            requestArtwork(for: merged, from: app)
        }
    }

    // MARK: Per-app state scripts

    private func fetchState(from app: PlayerApp) -> MediaPlaybackState? {
        let source: String
        switch app {
        case .spotify:
            source = """
            tell application "Spotify"
                if player state is stopped then return "STOPPED"
                set sep to (character id 31)
                set t to current track
                set pos to "0"
                try
                    set pos to (player position as string)
                end try
                set dur to "0"
                try
                    set dur to ((duration of t) as string)
                end try
                set shuf to "false"
                try
                    set shuf to (shuffling as string)
                end try
                set rep to "false"
                try
                    set rep to (repeating as string)
                end try
                set art to ""
                try
                    set art to (artwork url of t)
                end try
                return (name of t) & sep & (artist of t) & sep & (album of t) & sep & (player state as string) & sep & pos & sep & dur & sep & shuf & sep & rep & sep & art
            end tell
            """
        case .appleMusic:
            source = """
            tell application "Music"
                if player state is stopped then return "STOPPED"
                set sep to (character id 31)
                set t to current track
                set pos to "0"
                try
                    set pos to (player position as string)
                end try
                set dur to "0"
                try
                    set dur to ((duration of t) as string)
                end try
                set shuf to "false"
                try
                    set shuf to (shuffle enabled as string)
                end try
                set rep to "off"
                try
                    set rep to (song repeat as string)
                end try
                return (name of t) & sep & (artist of t) & sep & (album of t) & sep & (player state as string) & sep & pos & sep & dur & sep & shuf & sep & rep & sep & ""
            end tell
            """
        }

        guard let result = runScript(source),
              let text = result.stringValue else { return nil }
        if text == "STOPPED" { return nil }

        let parts = text.components(separatedBy: "\u{1F}")
        guard parts.count >= 9 else { return nil }

        let title = parts[0]
        let artist = parts[1]
        let album = parts[2]
        let isPlaying = parts[3].lowercased().contains("playing")
        let position = parseScriptNumber(parts[4])
        var duration = parseScriptNumber(parts[5])
        if app == .spotify { duration /= 1000 } // Spotify reports milliseconds

        var shuffle: MediaPlaybackState.ShuffleMode = .off
        if parts[6].lowercased() == "true" { shuffle = .songs }

        var repeatMode: MediaPlaybackState.RepeatMode = .off
        switch app {
        case .spotify:
            repeatMode = parts[7].lowercased() == "true" ? .all : .off
        case .appleMusic:
            switch parts[7].lowercased() {
            case "one": repeatMode = .one
            case "all": repeatMode = .all
            default: repeatMode = .off
            }
        }

        var state = MediaPlaybackState(
            title: title,
            artist: artist,
            album: album,
            bundleIdentifier: app.bundleIdentifier,
            appName: app.displayName,
            isPlaying: isPlaying,
            duration: duration,
            elapsed: position,
            timestamp: Date(),
            playbackRate: isPlaying ? 1 : 0,
            shuffleMode: shuffle,
            repeatMode: repeatMode
        )
        if app == .spotify {
            state.artworkRemoteURL = parts[8].isEmpty ? nil : parts[8]
        }
        return state
    }

    /// AppleScript renders numbers with the locale decimal separator.
    private func parseScriptNumber(_ raw: String) -> Double {
        Double(raw.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    // MARK: Artwork

    private func requestArtwork(for state: MediaPlaybackState, from app: PlayerApp) {
        guard !artworkFetchInFlight else { return }
        let identity = state.trackIdentity
        artworkFetchInFlight = true

        switch app {
        case .spotify:
            guard let urlString = state.artworkRemoteURL,
                  let url = URL(string: urlString) else {
                artworkFetchInFlight = false
                return
            }
            let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.artworkFetchInFlight = false
                    guard let data, let image = NSImage(data: data) else { return }
                    self.storeArtwork(image, identity: identity)
                }
            }
            task.resume()

        case .appleMusic:
            // `raw data of artwork` must run on the main thread (NSAppleScript);
            // only executed when the track changes.
            let source = """
            tell application "Music"
                try
                    return raw data of artwork 1 of current track
                on error
                    return ""
                end try
            end tell
            """
            defer { artworkFetchInFlight = false }
            guard let descriptor = runScript(source) else { return }
            let data = descriptor.data
            guard !data.isEmpty, let image = NSImage(data: data) else { return }
            storeArtwork(image, identity: identity)
        }
    }

    private func storeArtwork(_ image: NSImage, identity: String) {
        artworkIdentity = identity
        artworkImage = image
        refresh()
    }

    // MARK: Controls

    func togglePlayPause() { tell("playpause") }
    func nextTrack() { tell("next track") }
    func previousTrack() { tell("previous track") }

    func seek(to seconds: TimeInterval) {
        tell("set player position to \(Int(seconds))")
    }

    func setShuffle(_ on: Bool) {
        switch commandTarget() {
        case .spotify: tell("set shuffling to \(on)")
        case .appleMusic: tell("set shuffle enabled to \(on)")
        case nil: break
        }
    }

    func setRepeat(_ mode: MediaPlaybackState.RepeatMode) {
        switch commandTarget() {
        case .spotify:
            tell("set repeating to \(mode != .off)")
        case .appleMusic:
            let value: String
            switch mode {
            case .off: value = "off"
            case .one: value = "one"
            case .all: value = "all"
            }
            tell("set song repeat to \(value)")
        case nil:
            break
        }
    }

    private func commandTarget() -> PlayerApp? {
        if let restriction, restriction.isRunning { return restriction }
        if let activePlayer, activePlayer.isRunning { return activePlayer }
        return PlayerApp.allCases.first(where: \.isRunning)
    }

    private func tell(_ command: String) {
        guard let app = commandTarget() else { return }
        // cached: false — command sources vary (seek positions etc.), so caching
        // the compiled scripts would grow without bound.
        _ = runScript("tell application \"\(app.scriptTarget)\" to \(command)", cached: false)
        // Reflect the change quickly in the UI.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.refresh()
        }
    }

    // MARK: Script plumbing

    private func runScript(_ source: String, cached: Bool = true) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if cached, let existing = scriptCache[source] {
            script = existing
        } else {
            guard let fresh = NSAppleScript(source: source) else { return nil }
            if cached { scriptCache[source] = fresh }
            script = fresh
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -1743, !reportedPermissionDenial {
                // errAEEventNotPermitted — user denied Automation access.
                reportedPermissionDenial = true
                onPermissionDenied?()
            }
            return nil
        }
        return result
    }
}

/// System output volume via in-process AppleScript (StandardAdditions —
/// no Automation/TCC consent required, unlike targeting other apps).
enum MediaSystemVolume {
    /// 0.0 ... 1.0, nil if unavailable.
    @MainActor
    static func read() -> Double? {
        guard let script = NSAppleScript(source: "output volume of (get volume settings)") else {
            return nil
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        let value = result.int32Value
        return Double(value) / 100.0
    }

    @MainActor
    static func write(_ volume: Double) {
        let clamped = Int((volume * 100).rounded()).clamped(to: 0...100)
        guard let script = NSAppleScript(source: "set volume output volume \(clamped)") else {
            return
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
    }
}

extension Int {
    fileprivate func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
