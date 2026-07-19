import AppKit
import Combine
import SwiftUI
import MediaRemoteAdapter

/// Which media source the widget is allowed to display/control.
enum MediaSourceFilter: String, CaseIterable, Identifiable {
    case any
    case appleMusic
    case spotify

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .any: return "Any app"
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .any: return nil
        case .appleMusic: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }

    var scriptPlayer: MediaScriptPlayerController.PlayerApp? {
        switch self {
        case .any: return nil
        case .appleMusic: return .appleMusic
        case .spotify: return .spotify
        }
    }
}

/// App-wide now-playing hub. Streams system media state from the MediaRemote
/// adapter (perl loophole), automatically falls back to AppleScript control of
/// Spotify / Apple Music when the adapter yields nothing, and exposes controls,
/// artwork tint, quick-peek triggers, and the system output volume.
@MainActor
final class MusicManager: ObservableObject {
    static let shared = MusicManager()

    // MARK: Published state

    @Published private(set) var playback: MediaPlaybackState?
    /// Vivid tint derived from the average artwork color (for glows/visualizer).
    @Published private(set) var artworkTint: Color = .white.opacity(0.85)
    /// Icon of the app currently providing playback.
    @Published private(set) var sourceAppIcon: NSImage?
    /// True while the AppleScript Spotify/Music fallback is driving state.
    @Published private(set) var usingScriptFallback = false
    /// True when the user denied Automation consent for the fallback.
    @Published private(set) var automationPermissionDenied = false
    /// Set briefly when the song changes — the integrator shows
    /// `MediaQuickPeekView` next to the closed notch while this is true.
    @Published var showQuickPeek = false
    /// Snapshot to render inside the quick peek (kept stable during hide animation).
    @Published private(set) var quickPeekPlayback: MediaPlaybackState?
    /// System output volume 0...1 (read lazily; see `refreshSystemVolume`).
    @Published private(set) var systemVolume: Double = 0.5

    /// Whether the adapter's dylib + perl script could be located at all
    /// (false when build-app.sh did not bundle them — see INTEGRATION.md).
    nonisolated var adapterResourcesAvailable: Bool { MediaAdapterTransport.isAvailable }

    // MARK: Settings

    @AppStorage("media.enabled") var mediaEnabled = true {
        willSet { objectWillChange.send() }
        didSet { if oldValue != mediaEnabled { enabledDidChange() } }
    }
    @AppStorage("media.restrictTo") var restrictToRaw = MediaSourceFilter.any.rawValue {
        willSet { objectWillChange.send() }
        didSet { if oldValue != restrictToRaw { restrictionDidChange() } }
    }
    @AppStorage("media.showVisualizer") var showVisualizer = true {
        willSet { objectWillChange.send() }
    }

    var sourceFilter: MediaSourceFilter {
        get { MediaSourceFilter(rawValue: restrictToRaw) ?? .any }
        set { restrictToRaw = newValue.rawValue }
    }

    // MARK: Internals

    private let transport = MediaAdapterTransport()
    private let scriptController = MediaScriptPlayerController()

    private var started = false
    private var startDate = Date.distantPast
    private var adapterEverDelivered = false
    private var adapterRestartAttempts = 0
    private var fallbackProbeTask: Task<Void, Never>?
    private var quickPeekHideTask: Task<Void, Never>?
    private var iconCacheBundleID: String?
    private var pendingVolumeWrite: DispatchWorkItem?

    private init() {
        transport.onTrackInfo = { [weak self] info in
            // Transport already hops to the main queue.
            Task { @MainActor [weak self] in self?.ingestAdapter(info) }
        }
        transport.onTerminated = { [weak self] in
            Task { @MainActor [weak self] in self?.adapterTerminated() }
        }
        scriptController.onStateChanged = { [weak self] state in
            self?.ingest(state, fromFallback: true)
        }
        scriptController.onPermissionDenied = { [weak self] in
            self?.automationPermissionDenied = true
        }
    }

    // MARK: Lifecycle (call `start()` once at app launch)

    func start() {
        guard !started else { return }
        started = true
        startDate = Date()
        guard mediaEnabled else { return }
        beginListening()
    }

    func stop() {
        fallbackProbeTask?.cancel()
        transport.stop()
        scriptController.stop()
        usingScriptFallback = false
        playback = nil
    }

    private func beginListening() {
        adapterEverDelivered = false
        adapterRestartAttempts = 0
        scriptController.restriction = sourceFilter.scriptPlayer
        transport.start()
        scheduleFallbackProbe(after: 5)
        refreshSystemVolume()
    }

    private func enabledDidChange() {
        guard started else { return }
        if mediaEnabled {
            beginListening()
        } else {
            stop()
        }
    }

    private func restrictionDidChange() {
        scriptController.restriction = sourceFilter.scriptPlayer
        // Re-evaluate the current track against the new filter.
        if let current = playback,
           let required = sourceFilter.bundleIdentifier,
           current.bundleIdentifier != required {
            playback = nil
        }
        if usingScriptFallback { scriptController.refresh() }
    }

    // MARK: Adapter plumbing

    private func ingestAdapter(_ info: TrackInfo?) {
        adapterEverDelivered = true
        adapterRestartAttempts = 0
        if usingScriptFallback {
            // Adapter came alive — it is strictly better than the fallback.
            endScriptFallback()
        }
        ingest(info.map { MediaPlaybackState(payload: $0.payload) }, fromFallback: false)
    }

    private func adapterTerminated() {
        guard started, mediaEnabled else { return }
        adapterRestartAttempts += 1
        if adapterRestartAttempts <= 3 {
            let delay = Double(adapterRestartAttempts)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, self.started, self.mediaEnabled else { return }
                self.transport.start()
            }
        } else {
            beginScriptFallbackIfPossible()
        }
    }

    private func scheduleFallbackProbe(after seconds: TimeInterval) {
        fallbackProbeTask?.cancel()
        fallbackProbeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard self.started, self.mediaEnabled, !self.adapterEverDelivered else { return }
            self.beginScriptFallbackIfPossible()
        }
    }

    private func beginScriptFallbackIfPossible() {
        guard !usingScriptFallback else { return }
        let candidates = sourceFilter.scriptPlayer.map { [$0] }
            ?? MediaScriptPlayerController.PlayerApp.allCases
        guard candidates.contains(where: \.isRunning) else {
            // Try again later; a player may launch after us.
            scheduleFallbackProbe(after: 10)
            return
        }
        usingScriptFallback = true
        scriptController.restriction = sourceFilter.scriptPlayer
        scriptController.start()
    }

    private func endScriptFallback() {
        usingScriptFallback = false
        scriptController.stop()
    }

    // MARK: State ingestion (both sources funnel here)

    private func ingest(_ incoming: MediaPlaybackState?, fromFallback: Bool) {
        // Ignore fallback updates while the adapter is authoritative.
        if fromFallback && !usingScriptFallback { return }

        var state = incoming

        // Restrict-to-app filter.
        if let state_ = state,
           let required = sourceFilter.bundleIdentifier,
           let bid = state_.bundleIdentifier,
           bid != required {
            state = nil
        }

        let previous = playback

        // Carry artwork forward when an update for the same track omits it.
        if var state_ = state,
           let previous,
           state_.trackIdentity == previous.trackIdentity,
           state_.artworkImage == nil,
           previous.artworkImage != nil {
            state_.artworkImage = previous.artworkImage
            state = state_
        }

        playback = state

        updateDerived(previous: previous, current: state)
        maybeTriggerQuickPeek(previous: previous, current: state)
    }

    private func updateDerived(previous: MediaPlaybackState?, current: MediaPlaybackState?) {
        guard let current else {
            sourceAppIcon = nil
            iconCacheBundleID = nil
            return
        }

        // Recompute the tint only when the artwork actually changed.
        let artworkChanged = current.artworkImage !== previous?.artworkImage
        if artworkChanged {
            artworkTint = MediaArtworkColor.tint(for: current.artworkImage)
        }

        // Cache the source app icon per bundle id.
        if current.bundleIdentifier != iconCacheBundleID {
            iconCacheBundleID = current.bundleIdentifier
            if let bid = current.bundleIdentifier,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                sourceAppIcon = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                sourceAppIcon = nil
            }
        }
    }

    private func maybeTriggerQuickPeek(previous: MediaPlaybackState?, current: MediaPlaybackState?) {
        guard let current, current.hasContent else { return }
        let changed: Bool
        if let previous {
            changed = previous.trackIdentity != current.trackIdentity
        } else {
            // Fresh playback start: suppress the initial snapshot right after launch.
            changed = current.isPlaying && Date().timeIntervalSince(startDate) > 5
        }
        guard changed else { return }

        quickPeekPlayback = current
        showQuickPeek = true
        quickPeekHideTask?.cancel()
        quickPeekHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard let self, !Task.isCancelled else { return }
            self.showQuickPeek = false
        }
    }

    // MARK: Controls

    func togglePlayPause() {
        if usingScriptFallback {
            scriptController.togglePlayPause()
        } else {
            transport.send("toggle_play_pause")
        }
        // Optimistic flip so the UI reacts instantly.
        if var state = playback {
            let now = Date()
            state.elapsed = state.extrapolatedElapsed(at: now)
            state.timestamp = now
            state.isPlaying.toggle()
            state.playbackRate = state.isPlaying ? max(state.playbackRate, 1) : 0
            playback = state
        }
    }

    func nextTrack() {
        usingScriptFallback ? scriptController.nextTrack() : transport.send("next_track")
    }

    func previousTrack() {
        usingScriptFallback ? scriptController.previousTrack() : transport.send("previous_track")
    }

    func seek(to seconds: TimeInterval) {
        let clamped = max(0, seconds)
        if usingScriptFallback {
            scriptController.seek(to: clamped)
        } else {
            transport.send("set_time \(clamped)")
        }
        if var state = playback {
            state.elapsed = clamped
            state.timestamp = Date()
            playback = state
        }
    }

    func toggleShuffle() {
        let current = playback?.shuffleMode ?? .off
        let next: MediaPlaybackState.ShuffleMode = current == .off ? .songs : .off
        if usingScriptFallback {
            scriptController.setShuffle(next.isOn)
        } else {
            // MediaRemote's wire enum is 1-based: 1 off, 2 albums, 3 songs.
            let wire: Int
            switch next {
            case .off: wire = 1
            case .albums: wire = 2
            case .songs: wire = 3
            }
            transport.send("set_shuffle_mode \(wire)")
        }
        if var state = playback {
            state.shuffleMode = next
            playback = state
        }
    }

    func cycleRepeatMode() {
        let current = playback?.repeatMode ?? .off
        let next: MediaPlaybackState.RepeatMode
        switch current {
        case .off: next = .all
        case .all: next = .one
        case .one: next = .off
        }
        if usingScriptFallback {
            scriptController.setRepeat(next)
        } else {
            // MediaRemote's wire enum is 1-based: 1 off, 2 one, 3 all.
            transport.send("set_repeat_mode \(next.rawValue + 1)")
        }
        if var state = playback {
            state.repeatMode = next
            playback = state
        }
    }

    // MARK: System volume

    /// Re-read the system output volume (call from `onAppear` of the card).
    func refreshSystemVolume() {
        if let value = MediaSystemVolume.read() {
            systemVolume = value
        }
    }

    /// Live slider updates: published immediately, written with a short throttle.
    func setSystemVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        systemVolume = clamped
        pendingVolumeWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                MediaSystemVolume.write(self.systemVolume)
            }
        }
        pendingVolumeWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Opens the Automation pane so the user can grant AppleScript consent.
    func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        if let url { NSWorkspace.shared.open(url) }
    }
}
