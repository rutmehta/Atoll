import SwiftUI

/// Inline HUD rendered inside the CLOSED notch: an SF Symbol on the left wing,
/// a solid black bridge over the physical notch, and a draggable progress
/// capsule on the right wing (drags write back through the managers).
///
/// Intended usage (integrator, inside `ClosedNotchView`):
///
///     if SneakPeekCoordinator.shared.visible {
///         HUDWingView(notchWidth: vm.geometry.notchSize.width)
///     }
///
/// The view fills whatever closed-notch frame it is given (wings ≈ 90–120 pt
/// per side, height = notch height, ~28–36 pt).
struct HUDWingView: View {
    /// Width of the physical notch cutout so the wings sit on either side of it.
    var notchWidth: CGFloat

    @ObservedObject private var peek = SneakPeekCoordinator.shared

    var body: some View {
        HStack(spacing: 0) {
            HUDWingLeftView()
                .frame(maxWidth: .infinity)
            // Black bridge over the physical notch (matches the notch fill).
            Color.black
                .frame(width: max(notchWidth - 20, 0))
            HUDWingRightView()
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .opacity(peek.visible ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: peek.visible)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let percent = Int((peek.value * 100).rounded())
        switch peek.type {
        case .volume: return "Volume \(percent) percent"
        case .brightness: return "Brightness \(percent) percent"
        case .mute: return HUDVolumeManager.shared.isMuted ? "Muted" : "Volume \(percent) percent"
        }
    }
}

/// Left wing: SF Symbol for the current HUD type (speaker / sun / mute variants).
struct HUDWingLeftView: View {
    @ObservedObject private var peek = SneakPeekCoordinator.shared
    @ObservedObject private var volumeManager = HUDVolumeManager.shared

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 20, alignment: .center)
                .contentTransition(.symbolEffect(.replace))
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .animation(.easeOut(duration: 0.15), value: symbolName)
    }

    private var showsMutedState: Bool {
        volumeManager.isMuted && peek.type != .brightness
    }

    private var symbolName: String {
        switch peek.type {
        case .brightness:
            return peek.value < 0.35 ? "sun.min.fill" : "sun.max.fill"
        case .volume, .mute:
            if showsMutedState { return "speaker.slash.fill" }
            return volumeSymbol(for: peek.value)
        }
    }

    private var label: String {
        switch peek.type {
        case .brightness: return "Brightness"
        case .volume: return showsMutedState ? "Muted" : "Volume"
        case .mute: return showsMutedState ? "Muted" : "Volume"
        }
    }

    private func volumeSymbol(for value: Float) -> String {
        switch value {
        case ..<0.01: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

/// Right wing: draggable progress capsule. Dragging writes the new value back
/// through `HUDVolumeManager` / `HUDBrightnessManager`.
struct HUDWingRightView: View {
    @ObservedObject private var peek = SneakPeekCoordinator.shared
    @ObservedObject private var volumeManager = HUDVolumeManager.shared

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.2))
                Capsule()
                    .fill(.white.opacity(isDimmed ? 0.4 : 1))
                    .frame(width: width * CGFloat(min(max(peek.value, 0), 1)))
            }
            .frame(height: barHeight)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        peek.beginInteraction()
                        let fraction = Float(min(max(drag.location.x / width, 0), 1))
                        apply(fraction)
                    }
                    .onEnded { _ in
                        peek.endInteraction()
                    }
            )
            .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.9), value: peek.value)
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
    }

    private var barHeight: CGFloat {
        peek.isInteracting ? 7 : 5
    }

    private var isDimmed: Bool {
        volumeManager.isMuted && peek.type != .brightness
    }

    private func apply(_ fraction: Float) {
        switch peek.type {
        case .volume, .mute:
            if volumeManager.isMuted, fraction > 0 {
                volumeManager.setMuted(false, source: .internalControl)
            }
            volumeManager.setVolume(fraction, source: .internalControl)
        case .brightness:
            HUDBrightnessManager.shared.setBrightness(fraction)
        }
        peek.updateValue(fraction)
    }
}
