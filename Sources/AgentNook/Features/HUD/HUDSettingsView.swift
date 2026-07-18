import SwiftUI

/// Settings pane for the system-HUD replacement. Add as a tab/section in the
/// settings window.
struct HUDSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var interceptor = MediaKeyInterceptor.shared
    @ObservedObject private var brightnessManager = HUDBrightnessManager.shared
    @AppStorage(SneakPeekCoordinator.showOnExternalChangeKey) private var showOnExternalChange = true

    var body: some View {
        Form {
            Section {
                Toggle("Replace system HUD", isOn: replaceSystemHUDBinding)
                Text("Volume, brightness and mute changes appear inside the notch instead of the system bezel. Media keys are intercepted while this is on; turning it off restores the standard macOS HUD immediately.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if settings.replaceSystemHUD {
                    accessibilityStatusRow
                    if interceptor.axStatus && interceptor.tapCreationFailed {
                        statusRow(
                            symbol: "exclamationmark.triangle.fill",
                            color: .orange,
                            text: "Could not install the media-key event tap. Try toggling the setting off and on, or relaunch AgentNook."
                        )
                    }
                }
            } header: {
                Text("System HUD")
            }

            Section {
                Toggle("Show HUD when volume changes externally", isOn: $showOnExternalChange)
                Text("Also shows the notch HUD when volume or mute is changed by another app, AirPods, an external keyboard, or the menu-bar slider.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } header: {
                Text("External changes")
            }

            if !brightnessManager.isAvailable {
                Section {
                    statusRow(
                        symbol: "sun.max.trianglebadge.exclamationmark",
                        color: .secondary,
                        text: "Display brightness control is unavailable on this Mac; brightness keys are passed through to the system."
                    )
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            interceptor.refreshPermissionStatus()
        }
    }

    // MARK: - Bindings

    private var replaceSystemHUDBinding: Binding<Bool> {
        Binding(
            get: { settings.replaceSystemHUD },
            set: { enabled in
                settings.replaceSystemHUD = enabled
                if enabled && !interceptor.axStatus {
                    interceptor.requestPermission()
                } else {
                    interceptor.refreshPermissionStatus()
                }
            }
        )
    }

    // MARK: - Rows

    @ViewBuilder
    private var accessibilityStatusRow: some View {
        if interceptor.axStatus {
            statusRow(
                symbol: "checkmark.circle.fill",
                color: .green,
                text: "Accessibility access granted"
            )
        } else {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Accessibility access is required to intercept media keys")
                    .font(.system(size: 12))
                Spacer()
                Button("Grant Access…") {
                    interceptor.requestPermission()
                }
                Button("Open System Settings") {
                    openAccessibilitySettings()
                }
            }
        }
    }

    private func statusRow(symbol: String, color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
