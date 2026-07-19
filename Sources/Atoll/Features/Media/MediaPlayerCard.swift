import AppKit
import SwiftUI

/// Large now-playing card for the open notch (Home tab).
/// Artwork with tinted glow, marquee title/artist, draggable seek bar,
/// transport + shuffle/repeat controls, source app icon, system volume slider.
struct MediaPlayerCard: View {
    @ObservedObject private var manager = MusicManager.shared

    var body: some View {
        Group {
            if !manager.mediaEnabled {
                disabledState
            } else if let playback = manager.playback, playback.hasContent {
                playerBody(playback)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(
                    colors: [manager.artworkTint.opacity(0.16), Color.white.opacity(0.04)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .onAppear { manager.refreshSystemVolume() }
    }

    // MARK: Full player

    private func playerBody(_ playback: MediaPlaybackState) -> some View {
        // The info column is height-bounded so the whole block centers as one
        // unit in the (tall) card instead of stretching with dead space.
        HStack(alignment: .center, spacing: 16) {
            artwork(playback)
            VStack(alignment: .leading, spacing: 4) {
                sourceRow(playback)
                MediaMarqueeText(
                    text: playback.title.isEmpty ? "Unknown title" : playback.title,
                    font: .system(size: 15, weight: .semibold),
                    color: .white,
                    height: 20
                )
                MediaMarqueeText(
                    text: subtitle(playback),
                    font: .system(size: 12),
                    color: .white.opacity(0.6),
                    height: 16
                )
                Spacer(minLength: 4)
                MediaSeekBar(
                    playback: playback,
                    tint: manager.artworkTint,
                    onSeek: { manager.seek(to: $0) }
                )
                transportRow(playback)
                volumeRow
            }
            .frame(height: 152)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func subtitle(_ playback: MediaPlaybackState) -> String {
        if playback.album.isEmpty || playback.album == playback.title {
            return playback.artist
        }
        if playback.artist.isEmpty { return playback.album }
        return "\(playback.artist) — \(playback.album)"
    }

    private func artwork(_ playback: MediaPlaybackState) -> some View {
        ZStack {
            if let image = playback.artworkImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 152, height: 152)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: manager.artworkTint.opacity(0.5), radius: 24, y: 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 152, height: 152)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    )
            }
        }
        .scaleEffect(playback.isPlaying ? 1 : 0.94)
        .opacity(playback.isPlaying ? 1 : 0.8)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: playback.isPlaying)
    }

    private func sourceRow(_ playback: MediaPlaybackState) -> some View {
        HStack(spacing: 5) {
            if let icon = manager.sourceAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
            }
            Text(playback.appName ?? playback.bundleIdentifier ?? "Now Playing")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            if manager.usingScriptFallback {
                Text("script")
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 0)
            MediaAudioVisualizer(
                isPlaying: playback.isPlaying,
                tint: manager.artworkTint,
                barCount: 4,
                maxBarHeight: 11,
                barWidth: 2,
                spacing: 2
            )
        }
    }

    private func transportRow(_ playback: MediaPlaybackState) -> some View {
        HStack(spacing: 0) {
            MediaControlButton(
                systemImage: "shuffle",
                size: 12,
                active: playback.shuffleMode.isOn,
                tint: manager.artworkTint
            ) { manager.toggleShuffle() }
            Spacer()
            HStack(spacing: 22) {
                MediaControlButton(systemImage: "backward.fill", size: 15) {
                    manager.previousTrack()
                }
                MediaControlButton(
                    systemImage: playback.isPlaying ? "pause.fill" : "play.fill",
                    size: 22
                ) { manager.togglePlayPause() }
                    .frame(width: 26)
                MediaControlButton(systemImage: "forward.fill", size: 15) {
                    manager.nextTrack()
                }
            }
            Spacer()
            MediaControlButton(
                systemImage: playback.repeatMode == .one ? "repeat.1" : "repeat",
                size: 12,
                active: playback.repeatMode != .off,
                tint: manager.artworkTint
            ) { manager.cycleRepeatMode() }
        }
        .padding(.vertical, 2)
    }

    private var volumeRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
            Slider(
                value: Binding(
                    get: { manager.systemVolume },
                    set: { manager.setSystemVolume($0) }
                ),
                in: 0...1
            )
            .controlSize(.mini)
            .tint(manager.artworkTint)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: Empty / disabled states

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.3))
            Text("Nothing playing")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text("Play something in Music, Spotify, or your browser")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)

            if !manager.adapterResourcesAvailable {
                Text("MediaRemote adapter not bundled — only Spotify / Apple Music will be detected")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            if manager.automationPermissionDenied {
                Button {
                    manager.openAutomationSettings()
                } label: {
                    Label("Allow Automation access", systemImage: "lock.open")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        }
        .padding(16)
    }

    private var disabledState: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.slash")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.3))
            Text("Media controls are off")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Button("Enable") {
                manager.mediaEnabled = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.white.opacity(0.2))
        }
        .padding(16)
    }
}

// MARK: - Control button

private struct MediaControlButton: View {
    let systemImage: String
    var size: CGFloat = 14
    var active: Bool = false
    var tint: Color = .white
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? tint : .white.opacity(hovering ? 1 : 0.85))
                .frame(minWidth: 20, minHeight: 20)
                .contentShape(Rectangle())
                .scaleEffect(hovering ? 1.12 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
    }
}

// MARK: - Marquee text

/// Single-line text that scrolls horizontally (with a dwell pause) only when it
/// overflows its container; fades at the clip edges.
struct MediaMarqueeText: View {
    let text: String
    var font: Font = .system(size: 13, weight: .semibold)
    var color: Color = .white
    var height: CGFloat = 18

    @State private var textWidth: CGFloat = 0
    @State private var began = Date()

    private let gap: CGFloat = 28
    private let speed: CGFloat = 28 // points per second
    private let dwell: TimeInterval = 2

    var body: some View {
        GeometryReader { geo in
            let overflow = textWidth > geo.size.width + 1
            Group {
                if overflow {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                        scrollingContent(at: timeline.date)
                    }
                    .mask(edgeFade)
                } else {
                    label
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
        }
        .frame(height: height)
        .background(measurer)
        .onChange(of: text) {
            began = Date()
        }
    }

    private func scrollingContent(at date: Date) -> some View {
        let total = textWidth + gap
        let scrollDuration = Double(total / speed)
        let period = dwell + scrollDuration
        let phase = date.timeIntervalSince(began)
            .truncatingRemainder(dividingBy: period)
        let offset: CGFloat = phase < dwell || phase < 0
            ? 0
            : -CGFloat(phase - dwell) * speed
        return HStack(spacing: gap) {
            label
            label
        }
        .offset(x: max(offset, -total))
        .fixedSize()
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    private var edgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.04),
                .init(color: .black, location: 0.94),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var measurer: some View {
        label
            .hidden()
            .fixedSize()
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MediaTextWidthPreferenceKey.self,
                        value: proxy.size.width
                    )
                }
            )
            .onPreferenceChange(MediaTextWidthPreferenceKey.self) { width in
                textWidth = width
            }
            .frame(width: 0, height: 0)
            .clipped()
    }
}

private struct MediaTextWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Seek bar

/// Draggable progress bar with elapsed / remaining labels. Position is
/// extrapolated client-side from (elapsed, timestamp, rate) — no polling.
struct MediaSeekBar: View {
    let playback: MediaPlaybackState
    let tint: Color
    let onSeek: (TimeInterval) -> Void

    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: playback.isPlaying ? 0.5 : 3600)) { timeline in
            let duration = playback.duration
            let elapsed = playback.extrapolatedElapsed(at: timeline.date)
            let fraction: Double = {
                guard duration > 0 else { return 0 }
                return isScrubbing ? scrubFraction : min(max(elapsed / duration, 0), 1)
            }()
            let shownElapsed = isScrubbing ? scrubFraction * duration : elapsed

            VStack(spacing: 3) {
                GeometryReader { geo in
                    let barHeight: CGFloat = (hovering || isScrubbing) ? 7 : 4.5
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.16))
                        if duration > 0 {
                            Capsule()
                                .fill(tint)
                                .frame(width: max(barHeight, geo.size.width * fraction))
                        }
                    }
                    .frame(height: barHeight)
                    .frame(height: geo.size.height) // vertical centering
                    .animation(.easeOut(duration: 0.15), value: barHeight)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard duration > 0 else { return }
                                isScrubbing = true
                                scrubFraction = min(max(value.location.x / geo.size.width, 0), 1)
                            }
                            .onEnded { _ in
                                guard duration > 0 else { return }
                                onSeek(scrubFraction * duration)
                                isScrubbing = false
                            }
                    )
                }
                .frame(height: 12)
                .onHover { hovering = $0 }

                HStack {
                    Text(MediaPlaybackState.formatTime(shownElapsed))
                    Spacer()
                    if duration > 0 {
                        Text("-" + MediaPlaybackState.formatTime(max(duration - shownElapsed, 0)))
                    }
                }
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}
