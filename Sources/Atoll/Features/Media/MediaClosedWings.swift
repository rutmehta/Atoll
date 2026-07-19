import AppKit
import SwiftUI

/// Compact artwork thumbnail for the left wing of the closed notch.
/// Renders nothing when media is disabled or idle (integrator can gate
/// `wingWidth` on `MusicManager.shared.playback != nil`).
struct MediaClosedWingLeft: View {
    @ObservedObject private var manager = MusicManager.shared

    var body: some View {
        if manager.mediaEnabled, let playback = manager.playback, playback.hasContent {
            thumbnail(playback)
                .padding(.leading, 7)
                .frame(maxHeight: .infinity, alignment: .center)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
        }
    }

    @ViewBuilder
    private func thumbnail(_ playback: MediaPlaybackState) -> some View {
        Group {
            if let image = playback.artworkImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let icon = manager.sourceAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.1))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.5))
                    )
            }
        }
        .frame(width: 19, height: 19)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .opacity(playback.isPlaying ? 1 : 0.55)
        .animation(.easeOut(duration: 0.25), value: playback.isPlaying)
    }
}

/// Animated 4-bar audio visualizer for the right wing of the closed notch.
/// Animates only while playing; tinted with the artwork average color.
struct MediaClosedWingRight: View {
    @ObservedObject private var manager = MusicManager.shared

    var body: some View {
        // Only while actually playing — the paused stubs read as four mystery
        // dots in the closed bar (the artwork thumbnail already says "media").
        if manager.mediaEnabled,
           manager.showVisualizer,
           let playback = manager.playback,
           playback.hasContent,
           playback.isPlaying {
            MediaAudioVisualizer(
                isPlaying: true,
                tint: manager.artworkTint
            )
            .padding(.trailing, 9)
            .frame(maxHeight: .infinity, alignment: .center)
            .transition(.opacity.combined(with: .scale(scale: 0.6)))
        }
    }
}

/// Reusable N-bar "spectrograph" (sine-composite, no audio tap).
/// Freezes to short stubs when paused.
struct MediaAudioVisualizer: View {
    var isPlaying: Bool
    var tint: Color = .white
    var barCount: Int = 4
    var maxBarHeight: CGFloat = 13
    var barWidth: CGFloat = 2.5
    var spacing: CGFloat = 2.5

    private static let speeds: [Double] = [3.1, 4.3, 2.7, 3.7, 4.9, 2.3]
    private static let phases: [Double] = [0.0, 1.4, 2.6, 0.9, 1.9, 3.1]

    var body: some View {
        Group {
            if isPlaying {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
                    bars(time: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                bars(time: nil)
            }
        }
        .animation(.easeOut(duration: 0.3), value: isPlaying)
    }

    private func bars(time: TimeInterval?) -> some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: barWidth, height: barHeight(index: index, time: time))
            }
        }
        .frame(height: maxBarHeight)
    }

    private func barHeight(index: Int, time: TimeInterval?) -> CGFloat {
        guard let time else { return max(2.5, maxBarHeight * 0.22) }
        let speed = Self.speeds[index % Self.speeds.count]
        let phase = Self.phases[index % Self.phases.count]
        // Two stacked sines look less mechanical than one.
        let wave = (sin(time * speed + phase) + sin(time * speed * 1.7 + phase * 2.3)) / 2
        let normalized = (wave + 1) / 2 // 0...1
        return max(2.5, maxBarHeight * (0.25 + 0.75 * CGFloat(normalized)))
    }
}
