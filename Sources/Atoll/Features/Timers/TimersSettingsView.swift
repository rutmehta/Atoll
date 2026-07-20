import SwiftUI
import AppKit
import UserNotifications

/// Settings pane for the Timers widget: completion sound, auto-open behavior,
/// and notification-permission status with a graceful enable flow.
struct TimersSettingsView: View {
    @ObservedObject private var manager = TimerManager.shared

    var body: some View {
        Form {
            Section("Completion") {
                HStack {
                    Picker("Sound", selection: $manager.completionSoundName) {
                        ForEach(TimerManager.completionSoundOptions, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    Button {
                        manager.previewSound(named: manager.completionSoundName)
                    } label: {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(manager.completionSoundName == "None")
                    .help("Preview the selected sound")
                }
                Toggle("Open the notch when a timer completes", isOn: $manager.autoOpenOnComplete)
            }

            Section("Pomodoro") {
                Stepper("Focus: \(manager.pomodoroFocusMinutes) min",
                        value: $manager.pomodoroFocusMinutes, in: 5...90, step: 5)
                Stepper("Short break: \(manager.pomodoroShortBreakMinutes) min",
                        value: $manager.pomodoroShortBreakMinutes, in: 1...30)
                Stepper("Long break: \(manager.pomodoroLongBreakMinutes) min",
                        value: $manager.pomodoroLongBreakMinutes, in: 5...60, step: 5)
                Stepper("Sessions before long break: \(manager.pomodoroSessionsPerCycle)",
                        value: $manager.pomodoroSessionsPerCycle, in: 2...8)
                Toggle("Start next phase automatically", isOn: $manager.pomodoroAutoAdvance)
            }

            Section("Notifications") {
                notificationRow
            }
        }
        .formStyle(.grouped)
        .task { await manager.refreshNotificationStatus() }
    }

    @ViewBuilder
    private var notificationRow: some View {
        if !manager.notificationsAvailable {
            Label {
                Text("Notifications require the bundled Atoll.app build.")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
            }
        } else {
            switch manager.notificationAuthStatus {
            case .authorized, .provisional:
                Label {
                    Text("A banner is posted when a timer finishes — even if Atoll was quit.")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            case .denied:
                HStack {
                    Label {
                        Text("Notifications are turned off for Atoll.")
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "bell.slash")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open System Settings…") {
                        openNotificationSettings()
                    }
                }
            default:
                HStack {
                    Label {
                        Text("Allow notifications to get a banner when a timer finishes.")
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "bell.badge")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Enable Notifications") {
                        Task {
                            await manager.requestNotificationPermission()
                            await manager.refreshNotificationStatus()
                        }
                    }
                }
            }
        }
    }

    private func openNotificationSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
