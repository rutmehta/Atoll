import Foundation
import AppKit
import UserNotifications

/// User notifications for agent-session attention events.
///
/// - Requests notification authorization lazily on first use (never at launch).
/// - Respects `SettingsStore.agentsNotifyOnAttention` / `agentsNotifyOnCompletion`.
/// - Per-session 30s cooldown; muted entirely while a terminal/editor is frontmost
///   (the user is already looking at the session).
/// - Degrades gracefully when running unbundled (SPM binary) — UNUserNotificationCenter
///   requires a real bundle, so we fall back to a beep + log instead of crashing.
@MainActor
final class AgentNotifier {
    static let shared = AgentNotifier()

    private var lastNotified: [String: Date] = [:]
    private let cooldown: TimeInterval = 30
    private var authorizationRequested = false
    private var authorized = false

    /// UNUserNotificationCenter traps when the process has no bundle identifier.
    private var notificationCenterAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private init() {}

    /// Called by the session store after every state change.
    func sessionTransition(from previous: AgentSessionState,
                           session: AgentSession,
                           completedHint: Bool = false) {
        let settings = SettingsStore.shared
        let state = session.state
        guard state != previous || completedHint else { return }

        // Non-interactive (claude -p / codex exec) runs stay quiet.
        if session.interactive == false { return }

        var title: String?
        var body: String?

        switch state {
        case .permissionRequest where previous != .permissionRequest:
            guard settings.agentsNotifyOnAttention else { break }
            let tool = session.pendingPermission?.toolName ?? "a tool"
            title = "Approval needed: \(tool) in \(session.projectName)"
            body = session.pendingPermission?.inputSummary

        case .waitingForInput where previous != .waitingForInput:
            if completedHint {
                guard settings.agentsNotifyOnCompletion else { break }
                title = "Finished: \(session.projectName)"
                body = session.lastAssistantMessage
            } else {
                guard settings.agentsNotifyOnAttention else { break }
                // Only meaningful when the agent was actually doing something —
                // discovery inserts and idle churn shouldn't ping the user.
                guard previous.isBusy || previous == .permissionRequest else { break }
                title = "Needs input: \(session.projectName)"
                body = session.lastAssistantMessage
            }

        case .ended:
            guard settings.agentsNotifyOnCompletion, previous.isBusy else { break }
            title = "Finished: \(session.projectName)"
            body = session.lastAssistantMessage

        default:
            break
        }

        guard let title else { return }
        deliver(sessionKey: session.id, title: title, body: body)
    }

    // MARK: - Delivery

    private func deliver(sessionKey: String, title: String, body: String?) {
        // Muted while the user is already staring at a terminal.
        if AgentTerminalJump.frontmostIsTerminal() { return }

        // Per-session cooldown.
        let now = Date()
        if let last = lastNotified[sessionKey], now.timeIntervalSince(last) < cooldown { return }
        lastNotified[sessionKey] = now

        guard notificationCenterAvailable else {
            NSSound.beep()
            NSLog("AgentNook (unbundled): %@ — %@", title, body ?? "")
            return
        }

        ensureAuthorization { [weak self] granted in
            guard granted, let self else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            if let body, !body.isEmpty {
                content.body = String(body.prefix(180))
            }
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "agentnook.\(sessionKey).\(now.timeIntervalSince1970)",
                content: content,
                trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    NSLog("AgentNook: notification failed: \(error.localizedDescription)")
                }
            }
            _ = self // keep self alive semantics explicit
        }
    }

    private func ensureAuthorization(_ completion: @escaping @Sendable (Bool) -> Void) {
        if authorized {
            completion(true)
            return
        }
        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.authorized = granted }
                    completion(granted)
                }
            }
        } else {
            center.getNotificationSettings { settings in
                let ok = settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { AgentNotifier.shared.authorized = ok }
                    completion(ok)
                }
            }
        }
    }
}
