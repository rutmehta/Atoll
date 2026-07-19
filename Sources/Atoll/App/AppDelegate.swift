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
        setupDebugChannel()

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

        // Timer completion → open the tools tab on the Timers pane.
        TimerManager.shared.onCountdownFinished = { [weak self] in
            Task { @MainActor [weak self] in
                UserDefaults.standard.set(OpenNotchView.ToolPane.timers.rawValue,
                                          forKey: "tools.selectedPane")
                self?.primaryController()?.viewModel.open(tab: .tools)
            }
        }

        // Agent needs permission → open the Agents tab (opt-out via setting) and
        // make the panel key so the approval card's 1/2/3/Esc shortcuts work.
        AgentSessionStore.shared.$sessions
            .map { $0.values.contains { $0.pendingPermission != nil } }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pending in
                guard pending,
                      UserDefaults.standard.object(forKey: "agentsui.autoOpenOnPermission") as? Bool ?? true
                else { return }
                guard let controller = self?.primaryController() else { return }
                controller.viewModel.open(tab: .agents)
                controller.panel.makeKeyAndOrderFront(nil)
            }
            .store(in: &cancellables)

        // Display-related settings → rebuild the notch panels. objectWillChange
        // fires in willSet, so hop a runloop before reading, and only rebuild on
        // an actual change (slider drags fire this constantly).
        var displayConfig = (SettingsStore.shared.showOnAllDisplays,
                             SettingsStore.shared.fakeNotchOnExternalDisplays)
        var openSizeConfig = (SettingsStore.shared.openWidth, SettingsStore.shared.openHeight)
        SettingsStore.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let current = (SettingsStore.shared.showOnAllDisplays,
                               SettingsStore.shared.fakeNotchOnExternalDisplays)
                if current != displayConfig {
                    displayConfig = current
                    self.rebuildControllers()
                }
                let size = (SettingsStore.shared.openWidth, SettingsStore.shared.openHeight)
                if size != openSizeConfig {
                    openSizeConfig = size
                    self.controllers.forEach { $0.refreshGeometry() }
                }
            }
            .store(in: &cancellables)

        // Enabling the Bluetooth live activity at runtime must boot the monitor
        // (start() is idempotent; the TCC prompt fires on first IOBluetooth use).
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                if UserDefaults.standard.object(forKey: "systemEvents.bluetoothLiveActivity") as? Bool == true {
                    BluetoothMonitor.shared.start()
                }
            }
        }

        // ⌥⌘N toggles the nook.
        toggleHotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_N),
            modifiers: UInt32(cmdKey | optionKey)
        ) { [weak self] in
            self?.primaryController()?.viewModel.toggle()
        }
        if toggleHotKey == nil {
            NSLog("Atoll: global hotkey ⌥⌘N registration failed (conflict with another app?)")
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
            controller.viewModel.tab = NotchTab(rawValue: settings.defaultTabRaw) ?? .home
            controller.viewModel.onStateChange = { state in
                if state == .closed {
                    MirrorManager.shared.notchDidClose()
                }
            }
            return controller
        }
    }

    // MARK: Debug remote control

    /// Local-only automation channel for development, gated behind
    /// `defaults write com.rutmehta.atoll debug.remoteControl -bool YES`.
    /// Commands (posted as the distributed notification's object string):
    /// "open", "open:Home|Shelf|Agents|Tools", "close", "snapshot:/path.png".
    private func setupDebugChannel() {
        guard UserDefaults.standard.bool(forKey: "debug.remoteControl") else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.rutmehta.atoll.debug"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let command = note.object as? String ?? ""
            Task { @MainActor [weak self] in
                self?.handleDebugCommand(command)
            }
        }
    }

    private func handleDebugCommand(_ command: String) {
        guard let controller = controllers.first else { return }
        if command == "open" {
            controller.viewModel.open()
        } else if command.hasPrefix("open:") {
            let raw = String(command.dropFirst("open:".count))
            controller.viewModel.open(tab: NotchTab(rawValue: raw))
        } else if command == "close" {
            controller.viewModel.close()
        } else if command.hasPrefix("snapshot:") {
            let path = String(command.dropFirst("snapshot:".count))
            guard let view = controller.panel.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
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
            accessibilityDescription: "Atoll"
        )

        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "Toggle Nook", action: #selector(toggleNook), keyEquivalent: "")
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Atoll", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
            window.title = "Atoll Settings"
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
