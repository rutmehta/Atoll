import SwiftUI
import AppKit

/// Settings pane for agent monitoring; the integrator adds it as a
/// section/tab of the settings window (standard light/dark window styling).
struct AgentsSettingsView: View {
    @ObservedObject private var installer = AgentHookInstaller.shared
    @ObservedObject private var usage = AgentUsageManager.shared
    @ObservedObject private var store = AgentSessionStore.shared

    // Same keys/defaults as Core/SettingsStore — the engine reads these.
    @AppStorage("agentsNotifyOnAttention") private var notifyOnAttention = true
    @AppStorage("agentsNotifyOnCompletion") private var notifyOnCompletion = true
    @AppStorage("agentsIdleCutoffMinutes") private var idleCutoffMinutes = 30.0
    /// Read by the integrator: auto-open the Agents tab when a permission
    /// request arrives.
    @AppStorage("agentsui.autoOpenOnPermission") private var autoOpenOnPermission = true

    var body: some View {
        Form {
            hooksSection
            notificationsSection
            sessionsSection
            accountsSection
            advancedSection
        }
        .formStyle(.grouped)
        .onAppear {
            installer.refreshStatus()
            usage.probeAccounts()
        }
    }

    // MARK: Hooks

    private var hooksSection: some View {
        Section {
            LabeledContent("Claude Code") { statusChip(installer.claudeState) }
            LabeledContent("Codex") { statusChip(installer.codexState) }
            HStack(spacing: 10) {
                Button(installer.overallState == .notInstalled ? "Install Hooks" : "Reinstall / Update Hooks") {
                    installer.install()
                }
                Button("Uninstall", role: .destructive) {
                    installer.uninstall()
                }
                .disabled(installer.overallState == .notInstalled)
            }
        } header: {
            Text("Session hooks")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Atoll registers one shell script in ~/.claude/settings.json and ~/.codex/hooks.json so live sessions, tool activity and permission requests appear in the notch. All existing hook entries are preserved; uninstall removes only Atoll's entries.")
                if let error = installer.lastError {
                    Text(error).foregroundStyle(.red)
                }
                if !store.socketActive {
                    Text("Socket /tmp/atoll.sock is not active — hooks will be silent until Atoll can bind it (is another instance running?).")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func statusChip(_ state: AgentHookInstallState) -> some View {
        let (label, color): (String, Color)
        switch state {
        case .installed: (label, color) = ("Installed", .green)
        case .partial: (label, color) = ("Partial", .orange)
        case .notInstalled: (label, color) = ("Not installed", .secondary)
        }
        return Text(label)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    // MARK: Notifications

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Notify when a session needs attention", isOn: $notifyOnAttention)
            Toggle("Notify when a session finishes", isOn: $notifyOnCompletion)
            Toggle("Open Agents tab on permission requests", isOn: $autoOpenOnPermission)
        }
    }

    // MARK: Sessions

    private var sessionsSection: some View {
        Section {
            VStack(alignment: .leading) {
                Slider(value: $idleCutoffMinutes, in: 5...120, step: 5) {
                    Text("Idle cutoff")
                }
                Text("Sessions idle for \(Int(idleCutoffMinutes)) min are marked stale; silently removed at \(Int(idleCutoffMinutes) * 2) min.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Sessions")
        }
    }

    // MARK: Usage accounts

    private var accountsSection: some View {
        Section {
            LabeledContent("Claude Code") {
                accountLabel(usage.claudeAccountLabel,
                             missing: "Not signed in — usage bars unavailable")
            }
            LabeledContent("Codex") {
                accountLabel(usage.codexAccountLabel,
                             missing: "No ~/.codex/auth.json — usage bars unavailable")
            }
            Button("Re-check accounts") {
                usage.probeAccounts()
                usage.refresh(force: true)
            }
        } header: {
            Text("Usage accounts")
        } footer: {
            Text("Quota data reuses the CLIs' own credentials (Claude Code keychain item, ~/.codex/auth.json). Atoll never stores or transmits them anywhere else.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func accountLabel(_ label: String?, missing: String) -> some View {
        if let label {
            Label(label, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 12))
        } else {
            Text(missing)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        Section("Config folders") {
            HStack(spacing: 10) {
                Button("Open ~/.claude") {
                    NSWorkspace.shared.open(
                        AgentHookInstaller.claudeSettingsURL.deletingLastPathComponent())
                }
                Button("Open ~/.codex") {
                    NSWorkspace.shared.open(
                        AgentHookInstaller.codexHooksURL.deletingLastPathComponent())
                }
                Button("Open Atoll data") {
                    NSWorkspace.shared.open(
                        AgentHookInstaller.scriptURL.deletingLastPathComponent())
                }
            }
        }
    }
}
