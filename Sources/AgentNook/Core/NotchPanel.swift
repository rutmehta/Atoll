import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats over the notch on every space,
/// including over fullscreen apps.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchController: NSObject {
    let panel: NotchPanel
    let viewModel: NotchViewModel
    private let screen: NSScreen
    private var clickOutsideMonitor: Any?
    private var shrinkTask: Task<Void, Never>?

    /// Margin around the open content so shadows/hover targets aren't clipped.
    private let openPadding: CGFloat = 60
    /// Horizontal hover margin around the closed notch.
    private let closedPadding: CGFloat = 24

    init(screen: NSScreen, settings: SettingsStore) {
        self.screen = screen
        let geometry = NotchGeometry.forScreen(screen)
        self.viewModel = NotchViewModel(geometry: geometry, settings: settings)

        panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none

        let hosting = NSHostingView(
            rootView: NotchRootView()
                .environmentObject(viewModel)
                .environmentObject(settings)
        )
        hosting.wantsLayer = true
        panel.contentView = hosting

        viewModel.onStateChange = { [weak self] state in
            self?.stateChanged(state)
        }

        applyFrame(for: .closed, animatedContent: false)
        panel.orderFrontRegardless()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.viewModel.state == .open else { return }
                if !self.panel.frame.contains(NSEvent.mouseLocation) {
                    self.viewModel.close()
                }
            }
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func refreshGeometry() {
        viewModel.geometry = NotchGeometry.forScreen(screen)
        applyFrame(for: viewModel.state, animatedContent: false)
    }

    func tearDown() {
        panel.orderOut(nil)
    }

    private func stateChanged(_ state: NotchState) {
        shrinkTask?.cancel()
        switch state {
        case .open:
            // Grow the window immediately; SwiftUI animates the visible shape inside it.
            applyFrame(for: .open, animatedContent: true)
            panel.makeKeyAndOrderFront(nil)
        case .closed:
            // Let the close animation finish before shrinking the window.
            shrinkTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard let self, !Task.isCancelled, self.viewModel.state == .closed else { return }
                self.applyFrame(for: .closed, animatedContent: false)
            }
        }
    }

    private func applyFrame(for state: NotchState, animatedContent: Bool) {
        let geometry = viewModel.geometry
        let size: CGSize
        switch state {
        case .closed:
            size = CGSize(
                width: viewModel.closedSize.width + closedPadding * 2,
                height: viewModel.closedSize.height + 4
            )
        case .open:
            size = CGSize(
                width: max(viewModel.openSize.width, viewModel.closedSize.width) + openPadding * 2,
                height: viewModel.openSize.height + openPadding
            )
        }
        let frame = CGRect(
            x: geometry.screenFrame.midX - size.width / 2,
            y: geometry.screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
    }
}
