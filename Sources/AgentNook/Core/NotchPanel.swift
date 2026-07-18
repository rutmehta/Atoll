import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats over the notch on every space,
/// including over fullscreen apps. The window frame is always the full open
/// size, pinned top-center; all open/close morphing happens inside SwiftUI.
/// Transparent regions pass clicks through (NSHostingView hit-testing).
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Never clamp to the visible frame — the whole point is to sit over the
    /// menu bar / notch area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class NotchController: NSObject {
    let panel: NotchPanel
    let viewModel: NotchViewModel
    private let screen: NSScreen
    private var clickOutsideMonitor: Any?

    /// Margin around the open content so shadows aren't clipped.
    private let framePadding: CGFloat = 60

    init(screen: NSScreen, settings: SettingsStore) {
        self.screen = screen
        let geometry = NotchGeometry.forScreen(screen)
        self.viewModel = NotchViewModel(geometry: geometry, settings: settings)

        panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        // Set AFTER isFloatingPanel — the isFloatingPanel setter resets level to .floating.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

        let hosting = NSHostingView(
            rootView: NotchRootView()
                .environmentObject(viewModel)
                .environmentObject(settings)
        )
        hosting.wantsLayer = true
        panel.contentView = hosting

        applyFrame()
        panel.orderFrontRegardless()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.viewModel.state == .open, !self.viewModel.isPinned else { return }
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
        applyFrame()
    }

    func tearDown() {
        panel.orderOut(nil)
    }

    private func applyFrame() {
        let geometry = viewModel.geometry
        let size = CGSize(
            width: max(viewModel.openSize.width, viewModel.closedSize.width) + framePadding * 2,
            height: viewModel.openSize.height + framePadding
        )
        let frame = CGRect(
            x: geometry.screenFrame.midX - size.width / 2,
            y: geometry.screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
    }
}
