import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [NotchController] = []
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var toggleHotKey: GlobalHotKey?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        rebuildControllers()
        setupStatusItem()
        startManagers()
        wireIntegrations()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildControllers()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .agentNookOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.openSettings()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ShelfStore.shared.handleAppWillTerminate()
        NotesStore.shared.flush()
        AgentSessionStore.shared.stop()
    }

    // MARK: Managers

    private func startManagers() {
        MusicManager.shared.start()
        CalendarManager.shared.start()
        BatteryMonitor.shared.start()
        _ = ShelfStore.shared
        _ = TodosStore.shared
        _ = TimerManager.shared
        ShortcutsManager.shared.refresh()

        HUDVolumeManager.shared.start()
        HUDBrightnessManager.shared.start()
        MediaKeyInterceptor.shared.start()

        AgentSessionStore.shared.start()
        AgentHookInstaller.shared.refreshStatus()

        // Bluetooth triggers a TCC prompt on first use — defer a few seconds so
        // launch isn't a wall of dialogs, and only when the live activity is on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if UserDefaults.standard.object(forKey: "systemEvents.bluetoothLiveActivity") as? Bool ?? true {
                BluetoothMonitor.shared.start()
            }
        }
    }

    private func wireIntegrations() {
        // Drag a file toward the notch → open the shelf on the pointer's screen.
        DragDetector.shared.onDragNearNotch = { [weak self] in
            Task { @MainActor [weak self] in
                self?.controllerUnderMouse()?.viewModel.open(tab: .shelf)
            }
        }
        DragDetector.shared.start()

        // Timer completion → open the tools tab.
        TimerManager.shared.onCountdownFinished = { [weak self] in
            Task { @MainActor [weak self] in
                self?.primaryController()?.viewModel.open(tab: .tools)
            }
        }

        // Agent needs permission → open the Agents tab (opt-out via setting).
        AgentSessionStore.shared.$sessions
            .map { $0.values.contains { $0.pendingPermission != nil } }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pending in
                guard pending,
                      UserDefaults.standard.object(forKey: "agentsui.autoOpenOnPermission") as? Bool ?? true
                else { return }
                self?.primaryController()?.viewModel.open(tab: .agents)
            }
            .store(in: &cancellables)

        // ⌥⌘N toggles the nook.
        toggleHotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_N),
            modifiers: UInt32(cmdKey | optionKey)
        ) { [weak self] in
            self?.primaryController()?.viewModel.toggle()
        }
    }

    // MARK: Controllers

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
        controllers = screens.map { screen in
            let controller = NotchController(screen: screen, settings: settings)
            controller.viewModel.onStateChange = { state in
                if state == .closed {
                    MirrorManager.shared.notchDidClose()
                }
            }
            return controller
        }
    }

    private func primaryController() -> NotchController? {
        controllerUnderMouse() ?? controllers.first
    }

    private func controllerUnderMouse() -> NotchController? {
        let mouse = NSEvent.mouseLocation
        return controllers.first { $0.viewModel.geometry.screenFrame.contains(mouse) } ?? controllers.first
    }

    // MARK: Status item & settings window

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "sparkles.rectangle.stack",
            accessibilityDescription: "AgentNook"
        )

        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "Toggle Nook", action: #selector(toggleNook), keyEquivalent: "")
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit AgentNook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        if let quit = menu.items.last { quit.target = nil }
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleNook() {
        primaryController()?.viewModel.toggle()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
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
