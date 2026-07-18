import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [NotchController] = []
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        rebuildControllers()
        setupStatusItem()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildControllers()
            }
        }
    }

    private func rebuildControllers() {
        controllers.forEach { $0.tearDown() }
        controllers.removeAll()

        let settings = SettingsStore.shared
        var screens: [NSScreen]
        if settings.showOnAllDisplays {
            screens = NSScreen.screens
            if !settings.fakeNotchOnExternalDisplays {
                screens = screens.filter { $0.safeAreaInsets.top > 0 }
            }
        } else if let screen = NotchGeometry.preferredScreen() {
            screens = [screen]
        } else {
            screens = []
        }
        controllers = screens.map { NotchController(screen: $0, settings: settings) }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "sparkles.rectangle.stack",
            accessibilityDescription: "AgentNook"
        )

        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle Nook", action: #selector(toggleNook), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AgentNook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleNook() {
        controllers.first?.viewModel.toggle()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "AgentNook Settings"
            window.contentView = NSHostingView(
                rootView: SettingsRootView().environmentObject(SettingsStore.shared)
            )
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
