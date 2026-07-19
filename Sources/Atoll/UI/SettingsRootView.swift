import SwiftUI

struct SettingsRootView: View {
    @EnvironmentObject var settings: SettingsStore

    enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case liveActivities = "Live Activities"
        case media = "Media"
        case calendar = "Calendar"
        case shelf = "Shelf"
        case hud = "HUD"
        case system = "System"
        case agents = "Agents"
        case mirror = "Mirror"
        case timers = "Timers"
        case notes = "Notes"
        case todos = "To-dos"
        case shortcuts = "Shortcuts"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .general: return "gear"
            case .liveActivities: return "bolt.badge.clock"
            case .media: return "play.circle"
            case .calendar: return "calendar"
            case .shelf: return "tray.full"
            case .hud: return "rectangle.tophalf.inset.filled"
            case .system: return "battery.100.bolt"
            case .agents: return "sparkles.rectangle.stack"
            case .mirror: return "web.camera"
            case .timers: return "timer"
            case .notes: return "note.text"
            case .todos: return "checklist"
            case .shortcuts: return "app.connected.to.app.below.fill"
            }
        }
    }

    @State private var pane: Pane = .general

    var body: some View {
        HSplitView {
            List(Pane.allCases, selection: $pane) { item in
                Label(item.rawValue, systemImage: item.systemImage)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .frame(width: 170)

            paneContent
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 640, height: 520)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .general: GeneralSettingsView()
        case .liveActivities: LiveActivitySettingsView()
        case .media: MediaSettingsView()
        case .calendar: CalendarSettingsView()
        case .shelf: ShelfSettingsView()
        case .hud: HUDSettingsView()
        case .system: SystemEventsSettingsView()
        case .agents: AgentsSettingsView()
        case .mirror: MirrorSettingsView()
        case .timers: TimersSettingsView()
        case .notes: NotesSettingsView()
        case .todos: TodosSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        }
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Open on hover", isOn: $settings.openOnHover)
                if settings.openOnHover {
                    HStack {
                        Text("Hover delay")
                        Slider(value: $settings.hoverDelay, in: 0...1)
                        Text(String(format: "%.1fs", settings.hoverDelay))
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                Toggle("Haptic feedback", isOn: $settings.hapticFeedback)
            }
            Section("Displays") {
                Toggle("Show on all displays", isOn: $settings.showOnAllDisplays)
                Toggle("Simulate notch on external displays", isOn: $settings.fakeNotchOnExternalDisplays)
            }
            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        settings.launchAtLogin = newValue
                    }
                LabeledContent("Toggle shortcut", value: "⌥⌘N")
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = settings.launchAtLogin }
    }
}

struct LiveActivitySettingsView: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Closed-notch live activities") {
                Toggle("Now playing", isOn: $settings.mediaLiveActivity)
                Toggle("Timers", isOn: $settings.timerLiveActivity)
                Toggle("Battery & charging", isOn: $settings.batteryLiveActivity)
                Toggle("Agent sessions", isOn: $settings.agentsLiveActivity)
            }
        }
        .formStyle(.grouped)
    }
}
