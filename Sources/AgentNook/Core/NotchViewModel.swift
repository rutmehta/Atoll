import SwiftUI
import Combine

enum NotchState: Equatable {
    case closed
    case open
}

enum NotchTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case shelf = "Shelf"
    case agents = "Agents"
    case tools = "Tools"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .home: return "play.circle"
        case .shelf: return "tray.full"
        case .agents: return "sparkles.rectangle.stack"
        case .tools: return "wrench.and.screwdriver"
        }
    }
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var state: NotchState = .closed
    @Published var tab: NotchTab = .home
    @Published var geometry: NotchGeometry
    @Published var isHoveringClosedNotch = false
    /// Set while a drag-and-drop is hovering anywhere near the notch; forces the shelf open.
    @Published var isDropTargeted = false

    let settings: SettingsStore

    /// Size of the expanded notch content.
    var openSize: CGSize { CGSize(width: 640, height: 400) }
    /// Extra width added to each side of the closed notch for live-activity "wings".
    var wingWidth: CGFloat = 0

    var closedSize: CGSize {
        CGSize(width: geometry.notchSize.width + wingWidth * 2,
               height: geometry.notchSize.height)
    }

    private var hoverOpenTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?

    var onStateChange: ((NotchState) -> Void)?

    init(geometry: NotchGeometry, settings: SettingsStore) {
        self.geometry = geometry
        self.settings = settings
    }

    static let openAnimation = Animation.spring(response: 0.38, dampingFraction: 0.8)
    static let closeAnimation = Animation.spring(response: 0.32, dampingFraction: 0.9)

    func open(tab: NotchTab? = nil) {
        closeTask?.cancel()
        if let tab { self.tab = tab }
        guard state != .open else { return }
        withAnimation(Self.openAnimation) { state = .open }
        onStateChange?(.open)
    }

    func close(after delay: TimeInterval = 0) {
        hoverOpenTask?.cancel()
        closeTask?.cancel()
        guard state != .closed else { return }
        closeTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            withAnimation(Self.closeAnimation) { self.state = .closed }
            self.onStateChange?(.closed)
        }
    }

    func toggle() {
        state == .open ? close() : open()
    }

    func hoverChanged(_ hovering: Bool) {
        isHoveringClosedNotch = hovering
        guard settings.openOnHover else { return }
        if hovering {
            hoverOpenTask?.cancel()
            hoverOpenTask = Task { [weak self] in
                guard let self else { return }
                let delay = self.settings.hoverDelay
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                self.open()
            }
        } else {
            hoverOpenTask?.cancel()
        }
    }

    /// Called when the pointer leaves the open notch entirely.
    func mouseExitedOpenNotch() {
        guard state == .open, !isDropTargeted else { return }
        close(after: 0.25)
    }

    func cancelPendingClose() {
        closeTask?.cancel()
    }
}
