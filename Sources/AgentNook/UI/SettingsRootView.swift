import SwiftUI

struct SettingsRootView: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            LiveActivitySettingsView()
                .tabItem { Label("Live Activities", systemImage: "bolt.badge.clock") }
        }
        .frame(width: 560, height: 480)
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
