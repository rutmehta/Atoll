import SwiftUI

struct SettingsRootView: View {
    @EnvironmentObject var settings: SettingsStore

    enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case appearance = "Appearance"
        case layout = "Layout"
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
            case .appearance: return "paintbrush"
            case .layout: return "rectangle.3.group"
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
        case .appearance: AppearanceSettingsView()
        case .layout: LayoutSettingsView()
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

struct AppearanceSettingsView: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Background") {
                Picker("Style", selection: $settings.backgroundStyle) {
                    Text("Pure black").tag("black")
                    Text("Gradient").tag("gradient")
                    Text("Tinted by artwork").tag("artwork")
                }
                if settings.backgroundStyle == "gradient" {
                    ColorPicker("Gradient top", selection: colorBinding($settings.gradientStartHex), supportsOpacity: false)
                    ColorPicker("Gradient bottom", selection: colorBinding($settings.gradientEndHex), supportsOpacity: false)
                }
            }
            Section("Accent") {
                ColorPicker("Accent color", selection: colorBinding($settings.accentHex), supportsOpacity: false)
                Toggle("Border glow", isOn: $settings.showBorderGlow)
            }
            Section("Open nook size") {
                HStack {
                    Text("Width")
                    Slider(value: $settings.openWidth, in: 480...900, step: 20)
                    Text("\(Int(settings.openWidth)) pt").monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                HStack {
                    Text("Height")
                    Slider(value: $settings.openHeight, in: 300...560, step: 20)
                    Text("\(Int(settings.openHeight)) pt").monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                HStack {
                    Text("Corner radius")
                    Slider(value: $settings.openCornerRadius, in: 10...40)
                    Text("\(Int(settings.openCornerRadius))").monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct LayoutSettingsView: View {
    @EnvironmentObject var settings: SettingsStore

    private func tabBinding(_ tab: NotchTab) -> Binding<Bool> {
        Binding(
            get: {
                settings.visibleTabsCSV
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .contains(tab.rawValue)
            },
            set: { visible in
                var names = settings.visibleTabsCSV
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if visible {
                    if !names.contains(tab.rawValue) { names.append(tab.rawValue) }
                } else {
                    names.removeAll { $0 == tab.rawValue }
                }
                settings.visibleTabsCSV = names.joined(separator: ",")
            }
        )
    }

    var body: some View {
        Form {
            Section("Tabs") {
                ForEach(NotchTab.allCases) { tab in
                    Toggle(tab.rawValue, isOn: tabBinding(tab))
                        .disabled(tab == .home)
                }
                Picker("Default tab", selection: $settings.defaultTabRaw) {
                    ForEach(NotchTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab.rawValue)
                    }
                }
            }
            Section("Home tab") {
                Picker("Layout", selection: $settings.homeLayout) {
                    Text("Media + Calendar").tag("mediaCalendar")
                    Text("Media only").tag("mediaOnly")
                    Text("Calendar only").tag("calendarOnly")
                }
            }
        }
        .formStyle(.grouped)
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
