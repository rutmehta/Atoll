import SwiftUI
import AppKit

// MARK: - Shared UI helpers (module-internal)

/// Formatting + glyph helpers shared by the AgentsUI views.
enum AgentUIFormat {

    /// Compact relative timestamp: "now", "42s", "3m", "2h", "5d".
    static func relative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    /// "Resets in 2h 15m" from an absolute reset date.
    static func resetsIn(_ date: Date?) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSinceNow)
        guard seconds > 0 else { return "Resets soon" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "Resets in \(days)d \(hours)h" }
        if hours > 0 { return "Resets in \(hours)h \(minutes)m" }
        return "Resets in \(minutes)m"
    }

    /// SF Symbol for a tool name.
    static func toolSymbol(_ tool: String) -> String {
        switch tool {
        case "Bash", "BashOutput", "KillShell": return "terminal"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "pencil.line"
        case "Read": return "doc.text"
        case "Glob", "Grep": return "magnifyingglass"
        case "WebFetch": return "globe"
        case "WebSearch": return "globe.badge.chevron.backward"
        case "Task": return "arrow.triangle.branch"
        case "AskUserQuestion": return "questionmark.bubble"
        case "TodoWrite": return "checklist"
        case "ExitPlanMode", "EnterPlanMode": return "map"
        default:
            if tool.hasPrefix("mcp__") { return "puzzlepiece.extension" }
            return "hammer"
        }
    }

    /// Dot / accent color for a session state.
    static func stateColor(_ state: AgentSessionState) -> Color {
        switch state {
        case .idle: return Color(white: 0.55)
        case .working: return .blue
        case .runningTool: return .orange
        case .waitingForInput, .permissionRequest: return .red
        case .compacting: return .purple
        case .ended: return Color(white: 0.35)
        }
    }

    static func statePulses(_ state: AgentSessionState) -> Bool {
        state == .working || state.needsAttention
    }

    /// Human description of a session state (used as row subtitle fallback).
    static func stateLabel(_ session: AgentSession) -> String {
        switch session.state {
        case .idle: return session.isStale ? "Idle (stale)" : "Idle"
        case .working: return "Working…"
        case .runningTool:
            if let tool = session.toolEvents.last(where: { $0.status == .running }) {
                return "Running \(tool.name)…"
            }
            return "Running tool…"
        case .waitingForInput: return "Waiting for you"
        case .permissionRequest: return "Needs approval"
        case .compacting: return "Compacting context…"
        case .ended: return "Ended"
        }
    }

    /// Permission-mode badge label + color; nil for "default" / unknown.
    static func permissionBadge(_ mode: String?) -> (label: String, color: Color)? {
        switch mode {
        case "plan": return ("Plan", .purple)
        case "acceptEdits": return ("Accept Edits", .green)
        case "dontAsk": return ("Don't Ask", .orange)
        case "bypassPermissions": return ("Bypass", .red)
        case "auto": return ("Auto", .cyan)
        default: return nil
        }
    }

    /// "$3.42", "$0.004", "< $0.001".
    static func money(_ value: Double) -> String {
        if value == 0 { return "$0" }
        if value < 0.001 { return "< $0.001" }
        if value < 0.1 { return String(format: "$%.3f", value) }
        if value < 100 { return String(format: "$%.2f", value) }
        return String(format: "$%.0f", value)
    }

    /// "1.2M", "340K", "982".
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.0fK", Double(count) / 1_000) }
        return "\(count)"
    }

    /// Inline-markdown render with plain-text fallback.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// Short session id suffix for "#a1b2c3".
    static func shortId(_ sessionId: String) -> String {
        String(sessionId.replacingOccurrences(of: "-", with: "").suffix(6))
    }
}

/// Provider glyph: Claude = asterisk-like sparkle, Codex = angle brackets.
struct AgentProviderGlyph: View {
    let provider: AgentProvider
    var size: CGFloat = 11

    var body: some View {
        switch provider {
        case .claude:
            Image(systemName: "sparkle")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34)) // Claude coral
        case .codex:
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: size - 1, weight: .semibold))
                .foregroundStyle(Color(white: 0.85))
        }
    }
}

/// Colored session-state dot with an expanding pulse ring for busy/attention states.
struct AgentStateDot: View {
    let state: AgentSessionState
    var size: CGFloat = 8

    @State private var animating = false

    var body: some View {
        let color = AgentUIFormat.stateColor(state)
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.7), lineWidth: 1.5)
                    .scaleEffect(animating ? 2.4 : 1.0)
                    .opacity(animating ? 0 : 0.8)
            )
            .onAppear { restartPulse() }
            .onChange(of: state) { restartPulse() }
    }

    private func restartPulse() {
        animating = false
        guard AgentUIFormat.statePulses(state) else { return }
        withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
            animating = true
        }
    }
}

// MARK: - Panel

/// The open-notch "Agents" tab: approval takeover, session rows with expandable
/// activity feeds, usage bars and the cost dashboard.
struct AgentsPanelView: View {

    fileprivate enum Section: String, CaseIterable {
        case sessions = "Sessions"
        case usage = "Usage"
        case costs = "Costs"
    }

    @ObservedObject private var store = AgentSessionStore.shared
    @ObservedObject private var installer = AgentHookInstaller.shared
    @State private var section: Section = .sessions
    @State private var expandedKeys: Set<String> = []

    /// Called on Esc from the approval card (integrator: `vm.close()`).
    var onDismiss: (() -> Void)?

    init(onDismiss: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
    }

    private var pendingSession: AgentSession? {
        store.orderedSessions.first { $0.pendingPermission != nil }
    }

    var body: some View {
        VStack(spacing: 8) {
            if let pending = pendingSession, let payload = pending.pendingPermission {
                AgentApprovalCardView(session: pending, payload: payload, onDismiss: onDismiss)
                otherSessionsStrip(excluding: pending.id)
            } else {
                header
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.85),
                   value: pendingSession?.pendingPermission?.key)
        .onAppear {
            installer.refreshStatus()
            AgentUsageManager.shared.setPanelVisible(true)
            AgentCostScanner.shared.rescan()
        }
        .onDisappear {
            AgentUsageManager.shared.setPanelVisible(false)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(Section.allCases, id: \.rawValue) { s in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { section = s }
                } label: {
                    Text(s.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(section == s ? Color.white.opacity(0.14) : .clear)
                        )
                        .foregroundStyle(section == s ? .white : Color(white: 0.6))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if store.liveSessionCount > 0 {
                Text("\(store.liveSessionCount) live")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color(white: 0.55))
            }
            if !store.socketActive {
                Label("Socket unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
                    .help("Could not bind /tmp/agentnook.sock — is another AgentNook running?")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .sessions: sessionList
        case .usage: AgentUsageBarsView()
        case .costs: AgentCostDashboard()
        }
    }

    // MARK: Sessions

    @ViewBuilder
    private var sessionList: some View {
        let sessions = store.orderedSessions.filter { $0.state != .ended || $0.endedAt != nil }
        if sessions.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(sessions) { session in
                        AgentSessionRow(
                            session: session,
                            expanded: expandedKeys.contains(session.id),
                            toggleExpanded: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    if expandedKeys.contains(session.id) {
                                        expandedKeys.remove(session.id)
                                    } else {
                                        expandedKeys.insert(session.id)
                                    }
                                }
                            })
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    /// Compressed list under an approval card so other sessions stay visible.
    @ViewBuilder
    private func otherSessionsStrip(excluding key: String) -> some View {
        let others = store.orderedSessions.filter { $0.id != key && $0.state != .ended }
        if !others.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(others) { session in
                        HStack(spacing: 5) {
                            AgentStateDot(state: session.state, size: 6)
                            Text(session.projectName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color(white: 0.75))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                }
            }
            .frame(height: 24)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 26))
                .foregroundStyle(Color(white: 0.45))
            Text("No agent sessions")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            if installer.overallState == .installed {
                Text("Start `claude` or `codex` in a terminal and the session will appear here.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            } else {
                Text("AgentNook watches Claude Code and Codex through lightweight shell hooks. Install them to see live sessions, approve permissions from the notch, and get notified when an agent needs you.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button {
                    installer.install()
                } label: {
                    Label("Install hooks", systemImage: "bolt.badge.checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(0.16))
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Text("Adds entries to ~/.claude/settings.json and ~/.codex/hooks.json — existing settings are preserved, uninstall any time in Settings.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color(white: 0.45))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                if let error = installer.lastError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Session row

private struct AgentSessionRow: View {
    let session: AgentSession
    let expanded: Bool
    let toggleExpanded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            if expanded {
                AgentActivityFeed(session: session)
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(session.state.needsAttention ? 0.10 : 0.06))
        )
        .opacity(session.isStale || session.state == .ended ? 0.55 : 1)
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            AgentStateDot(state: session.state)
            AgentProviderGlyph(provider: session.provider)

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 5) {
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("#\(AgentUIFormat.shortId(session.sessionId))")
                        .font(.system(size: 10, weight: .medium).monospaced())
                        .foregroundStyle(Color(white: 0.45))
                    if let badge = AgentUIFormat.permissionBadge(session.permissionMode) {
                        Text(badge.label)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(badge.color.opacity(0.22)))
                            .overlay(Capsule().stroke(badge.color.opacity(0.45), lineWidth: 0.5))
                            .foregroundStyle(badge.color)
                    }
                    if session.interactive == false {
                        Text("headless")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color(white: 0.45))
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.62))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(AgentUIFormat.relative(session.lastActivity))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color(white: 0.5))

            Button(action: toggleExpanded) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(white: 0.6))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse activity" : "Show activity")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !AgentTerminalJump.jump(to: session) {
                // Nothing to activate (discovered session with no PID) — expand instead.
                toggleExpanded()
            }
        }
        .help("Click to jump to this session's terminal")
    }

    private var subtitle: String {
        if session.state.isBusy || session.state.needsAttention {
            return AgentUIFormat.stateLabel(session)
        }
        if let prompt = session.lastUserPrompt, !prompt.isEmpty {
            return prompt.replacingOccurrences(of: "\n", with: " ")
        }
        return AgentUIFormat.stateLabel(session)
    }
}

// MARK: - Activity feed

private struct AgentActivityFeed: View {
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            if session.toolEvents.isEmpty && session.lastAssistantMessage == nil {
                Text("No activity yet")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.45))
                    .padding(.vertical, 2)
            }

            ForEach(session.toolEvents.suffix(8).reversed()) { event in
                HStack(spacing: 6) {
                    Image(systemName: AgentUIFormat.toolSymbol(event.name))
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.7))
                        .frame(width: 14)
                    Text(event.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(white: 0.85))
                    Text(event.inputSummary)
                        .font(.system(size: 10.5).monospaced())
                        .foregroundStyle(Color(white: 0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    statusIcon(event.status)
                }
            }

            if let message = session.lastAssistantMessage, !message.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    AgentProviderGlyph(provider: session.provider, size: 9)
                        .frame(width: 14)
                        .padding(.top, 2)
                    Text(AgentUIFormat.markdown(message))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color(white: 0.85))
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: AgentToolEvent.Status) -> some View {
        switch status {
        case .running:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.55)
                .frame(width: 14, height: 14)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green.opacity(0.85))
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red.opacity(0.9))
        }
    }
}
