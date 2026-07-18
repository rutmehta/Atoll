import AVFoundation
import SwiftUI

/// Settings pane for the mirror: default camera and mirroring toggle.
/// The integrator adds this as a tab/section of the settings window.
struct MirrorSettingsView: View {
    @ObservedObject private var manager = MirrorManager.shared

    var body: some View {
        Form {
            Section("Mirror") {
                Picker("Default camera", selection: $manager.selectedCameraID) {
                    Text("Automatic").tag("")
                    ForEach(manager.devices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                    // Keep a stale (disconnected) selection representable so the
                    // picker doesn't silently reset the persisted value.
                    if !manager.selectedCameraID.isEmpty,
                       !manager.devices.contains(where: { $0.uniqueID == manager.selectedCameraID }) {
                        Text("Last selected camera (disconnected)")
                            .tag(manager.selectedCameraID)
                    }
                }
                Toggle("Flip preview horizontally (mirror)", isOn: $manager.isMirrored)
            }
            if manager.authStatus == .denied || manager.authStatus == .restricted {
                Section {
                    LabeledContent("Camera access") {
                        Button("Open System Settings") {
                            MirrorManager.openCameraPrivacySettings()
                        }
                    }
                    Text("Camera access is currently disabled for AgentNook, so the mirror can't show a preview.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            manager.refreshAuthStatus()
            manager.refreshDevices()
        }
    }
}
