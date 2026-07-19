import AppKit
import SwiftUI

/// Compact artwork + title slide-in shown next to the closed notch when the
/// song changes. The integrator overlays this while
/// `MusicManager.shared.showQuickPeek` is true (auto-clears after ~2.8 s), e.g.:
///
///     if musicManager.showQuickPeek {
///         MediaQuickPeekView()
///             .transition(.move(edge: .top).combined(with: .opacity))
///     }
struct MediaQuickPeekView: View {
    @ObservedObject private var manager = MusicManager.shared

    var body: some View {
        if let playback = manager.quickPeekPlayback {
            HStack(spacing: 8) {
                artwork(playback)
                VStack(alignment: .leading, spacing: 0) {
                    Text(playback.title.isEmpty ? "Unknown title" : playback.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !playback.artist.isEmpty {
                        Text(playback.artist)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 170, alignment: .leading)
                MediaAudioVisualizer(
                    isPlaying: playback.isPlaying,
                    tint: manager.artworkTint,
                    barCount: 3,
                    maxBarHeight: 10,
                    barWidth: 2,
                    spacing: 2
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func artwork(_ playback: MediaPlaybackState) -> some View {
        Group {
            if let image = playback.artworkImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
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
        .frame(width: 18, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
