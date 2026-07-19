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

        // Bluetooth triggers a modal TCC prompt on first use (which blocks the
        // main thread) — never auto-start it. Start only when macOS already
        // granted access, or when the user explicitly enabled the toggle
        // (explicit = present in the persistent domain, not a registered default).
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if Self.bluetoothExplicitlyWanted {
                BluetoothMonitor.shared.start()
            }
        }
    }

    private static var bluetoothExplicitlyWanted: Bool {
        let domain = Bundle.main.bundleIdentifier.flatMap {
            UserDefaults.standard.persistentDomain(forName: $0)
        }
        guard let explicit = domain?["systemEvents.bluetoothLiveActivity"] as? Bool else {
            return false // registered default only — user never chose; avoid the TCC prompt
        }
        return explicit
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
        // Open-size changes are handled inside each NotchController.
        var displayConfig = (SettingsStore.shared.showOnAllDisplays,
                             SettingsStore.shared.fakeNotchOnExternalDisplays)
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
            }
            .store(in: &cancellables)

        // Enabling the Bluetooth live activity at runtime boots the monitor
        // (start() is idempotent; the TCC prompt fires on first IOBluetooth use,
        // which is fine here because the user just flipped the toggle).
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                if Self.bluetoothExplicitlyWanted {
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
        } else if command.hasPrefix("set:") {
            // "set:openWidth:800" — writes through SettingsStore, exercising the
            // exact same path as the settings sliders.
            let parts = command.dropFirst("set:".count).split(separator: ":")
            if parts.count == 2, let value = Double(parts[1]) {
                switch parts[0] {
                case "openWidth": SettingsStore.shared.openWidth = value
                case "openHeight": SettingsStore.shared.openHeight = value
                default: break
                }
            }
        } else if command == "axstatus" {
            try? (AXIsProcessTrusted() ? "trusted" : "untrusted")
                .write(toFile: "/tmp/atoll-axstatus", atomically: true, encoding: .utf8)
        } else if command == "axprompt" {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        } else if command.hasPrefix("click:") {
            // "click:x,y" in screen points (top-left origin). Posts a real
            // mouse down/up pair so actual hit-testing is exercised.
            let parts = command.dropFirst("click:".count).split(separator: ",")
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return }
            let point = CGPoint(x: x, y: y)
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type,
                        mouseCursorPosition: point, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
                usleep(60_000)
            }
        } else if command.hasPrefix("move:") {
            let parts = command.dropFirst("move:".count).split(separator: ",")
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return }
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?
                .post(tap: .cghidEventTap)
        } else if command.hasPrefix("key:") {
            // "key:keycode[,cmd][,opt][,shift][,ctrl]"
            let parts = command.dropFirst("key:".count).split(separator: ",").map(String.init)
            guard let code = parts.first.flatMap({ UInt16($0) }) else { return }
            var flags: CGEventFlags = []
            if parts.contains("cmd") { flags.insert(.maskCommand) }
            if parts.contains("opt") { flags.insert(.maskAlternate) }
            if parts.contains("shift") { flags.insert(.maskShift) }
            if parts.contains("ctrl") { flags.insert(.maskControl) }
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
                usleep(40_000)
            }
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
