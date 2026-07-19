import SwiftUI

/// Settings pane for the media widget — add as a section/tab of the
/// settings window.
struct MediaSettingsView: View {
    @ObservedObject private var manager = MusicManager.shared

    var body: some View {
        Form {
            Section("Now Playing") {
                Toggle("Show media controls", isOn: $manager.mediaEnabled)

                Picker("Show media from", selection: Binding(
                    get: { manager.sourceFilter },
                    set: { manager.sourceFilter = $0 }
                )) {
                    ForEach(MediaSourceFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .disabled(!manager.mediaEnabled)

                Toggle("Audio visualizer in the notch", isOn: $manager.showVisualizer)
                    .disabled(!manager.mediaEnabled)
            }

            Section("Status") {
                statusRow(
                    ok: manager.adapterResourcesAvailable,
                    okText: "MediaRemote adapter available",
                    failText: "MediaRemote adapter not bundled — using app-specific fallback only"
                )
                if manager.usingScriptFallback {
                    statusRow(
                        ok: true,
                        okText: "Using AppleScript fallback (\(manager.playback?.appName ?? "Spotify / Apple Music"))",
                        failText: ""
                    )
                }
                if manager.automationPermissionDenied {
                    HStack {
                        statusRow(
                            ok: false,
                            okText: "",
                            failText: "Automation access denied for Spotify / Music"
                        )
                        Spacer()
                        Button("Open Settings") {
                            manager.openAutomationSettings()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func statusRow(ok: Bool, okText: String, failText: String) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(ok ? Color.green.opacity(0.85) : Color.orange.opacity(0.9))
                .frame(width: 7, height: 7)
            Text(ok ? okText : failText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}
