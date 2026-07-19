import SwiftUI
import Combine

/// Where a volume/brightness change originated.
enum HUDEventSource: Equatable {
    /// Our own media-key interception or a drag on the notch HUD.
    case internalControl
    /// Changed by another app, the menu-bar slider, AirPods, an external device, etc.
    case external
}

/// What the inline notch HUD is currently showing.
enum SneakPeekType: Equatable {
    case volume
    case brightness
    case mute
}

/// Central coordinator for the closed-notch "sneak peek" HUD.
/// Managers and the media-key interceptor call `show(...)`; the closed-notch
/// wing views observe `visible` / `type` / `value` and render accordingly.
@MainActor
final class SneakPeekCoordinator: ObservableObject {
    static let shared = SneakPeekCoordinator()

    @Published private(set) var visible = false
    @Published private(set) var type: SneakPeekType = .volume
    @Published private(set) var value: Float = 0
    @Published private(set) var lastEventSource: HUDEventSource = .internalControl
    /// True while the user is dragging the HUD progress capsule (auto-hide paused).
    @Published private(set) var isInteracting = false

    static let displayDuration: TimeInterval = 1.5
    static let showOnExternalChangeKey = "hud.showOnExternalChange"

    private var hideTask: Task<Void, Never>?

    private init() {
        UserDefaults.standard.register(defaults: [Self.showOnExternalChangeKey: true])
    }

    /// Show (or refresh) the HUD. Resets the 1.5 s auto-hide timer.
    func show(type: SneakPeekType, value: Float, source: HUDEventSource = .internalControl) {
        self.type = type
        self.value = min(max(value, 0), 1)
        self.lastEventSource = source
        if !visible {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { visible = true }
        }
        scheduleAutoHide()
    }

    /// Called by the managers when a change originated outside the app.
    /// Honors the "show on external change" setting.
    func showExternalChange(type: SneakPeekType, value: Float) {
        guard UserDefaults.standard.bool(forKey: Self.showOnExternalChangeKey) else { return }
        show(type: type, value: value, source: .external)
    }

    /// Update the displayed value without changing type/source (used by drags).
    func updateValue(_ newValue: Float) {
        value = min(max(newValue, 0), 1)
    }

    /// Pause auto-hide while the user drags the HUD capsule.
    func beginInteraction() {
        guard !isInteracting else { return }
        isInteracting = true
        hideTask?.cancel()
    }

    func endInteraction() {
        guard isInteracting else { return }
        isInteracting = false
        scheduleAutoHide()
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        withAnimation(.easeOut(duration: 0.2)) { visible = false }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard !isInteracting else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.displayDuration * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.visible = false }
        }
    }
}
