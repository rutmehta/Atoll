import SwiftUI

/// Settings pane for battery + Bluetooth live activities.
/// The integrator adds this as a tab/section of the settings window.
@MainActor
struct SystemEventsSettingsView: View {
    // "batteryLiveActivity" is the shared master toggle also exposed by
    // SettingsStore / LiveActivitySettingsView — same UserDefaults key on purpose.
    @AppStorage("batteryLiveActivity") private var batteryLiveActivity = true
    @AppStorage("systemEvents.showBatteryPercentAlways") private var showPercentAlways = false
    @AppStorage("systemEvents.lowBatteryAlerts") private var lowBatteryAlerts = true
    @AppStorage("systemEvents.bluetoothLiveActivity") private var bluetoothLiveActivity = true

    @ObservedObject private var battery = BatteryMonitor.shared
    @ObservedObject private var bluetooth = BluetoothMonitor.shared

    var body: some View {
        Form {
            Section {
                Toggle("Battery live activity", isOn: $batteryLiveActivity)
                Toggle("Always show percentage", isOn: $showPercentAlways)
                Toggle("Low battery alerts", isOn: $lowBatteryAlerts)
                    .disabled(!batteryLiveActivity)
            } header: {
                Text("Battery")
            } footer: {
                Text("Shows charging, unplugged, fully charged and low battery (20% / 10%) events beside the notch. Low Power Mode changes are shown too.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Bluetooth live activity", isOn: $bluetoothLiveActivity)
                if bluetooth.permissionDenied {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Bluetooth access is disabled for AgentNook, so device events can't be detected.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Button("Open Privacy Settings…") {
                                BluetoothMonitor.openBluetoothPrivacySettings()
                            }
                            .font(.system(size: 12))
                        }
                    }
                    .padding(.vertical, 2)
                } else if !bluetooth.connectedDeviceNames.isEmpty {
                    LabeledContent("Connected now") {
                        Text(bluetooth.connectedDeviceNames.joined(separator: ", "))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("Bluetooth")
            } footer: {
                Text("Shows device connect and disconnect events beside the notch.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Picks up a permission change made while the pane was closed.
            bluetooth.retryAfterPermissionChange()
        }
    }
}
