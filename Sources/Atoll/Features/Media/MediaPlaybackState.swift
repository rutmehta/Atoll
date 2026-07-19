import AppKit
import Foundation

/// Snapshot of system-wide "now playing" state, source-agnostic
/// (MediaRemote adapter or AppleScript fallback).
struct MediaPlaybackState {
    enum ShuffleMode: Int {
        case off = 0
        case songs = 1
        case albums = 2

        var isOn: Bool { self != .off }
    }

    enum RepeatMode: Int {
        case off = 0
        case one = 1
        case all = 2
    }

    var title: String
    var artist: String
    var album: String
    var artworkImage: NSImage?
    var bundleIdentifier: String?
    var appName: String?
    var isPlaying: Bool
    /// Track length in seconds. 0 when unknown (live streams etc.).
    var duration: TimeInterval
    /// Playback position (seconds) that was valid at `timestamp`.
    var elapsed: TimeInterval
    /// Moment `elapsed` was sampled — used for client-side extrapolation.
    var timestamp: Date
    /// 1.0 while playing, 0 while paused (other rates possible for podcasts).
    var playbackRate: Double
    var shuffleMode: ShuffleMode
    var repeatMode: RepeatMode
    /// Remote artwork URL (Spotify AppleScript fallback) fetched lazily.
    var artworkRemoteURL: String?

    init(
        title: String = "",
        artist: String = "",
        album: String = "",
        artworkImage: NSImage? = nil,
        bundleIdentifier: String? = nil,
        appName: String? = nil,
        isPlaying: Bool = false,
        duration: TimeInterval = 0,
        elapsed: TimeInterval = 0,
        timestamp: Date = Date(),
        playbackRate: Double = 0,
        shuffleMode: ShuffleMode = .off,
        repeatMode: RepeatMode = .off
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkImage = artworkImage
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.isPlaying = isPlaying
        self.duration = duration
        self.elapsed = elapsed
        self.timestamp = timestamp
        self.playbackRate = playbackRate
        self.shuffleMode = shuffleMode
        self.repeatMode = repeatMode
    }

    /// Identity of the track (not the playback position) — used to detect song changes.
    var trackIdentity: String { "\(title)\u{1F}\(artist)\u{1F}\(album)" }

    /// Extrapolated playback position at `date` without polling.
    func extrapolatedElapsed(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return clamped(elapsed) }
        let rate = playbackRate > 0 ? playbackRate : 1
        return clamped(elapsed + date.timeIntervalSince(timestamp) * rate)
    }

    private func clamped(_ value: TimeInterval) -> TimeInterval {
        let low = max(0, value)
        guard duration > 0 else { return low }
        return min(low, duration)
    }

    var hasContent: Bool { !title.isEmpty || !artist.isEmpty }

    /// "3:41" / "1:02:11" style formatting.
    static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
