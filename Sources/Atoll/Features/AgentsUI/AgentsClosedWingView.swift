import SwiftUI

/// Closed-notch wing: one 5 pt dot per live session (max 5 + overflow count),
/// colored by state, pulsing red when a session needs attention. Renders
/// nothing when there are no live sessions (integrator can gate `wingWidth`
/// on `AgentSessionStore.shared.liveSessionCount > 0`).
struct AgentsClosedWingView: View {
    @ObservedObject private var store = AgentSessionStore.shared

    /// Integrator: `vm.open(tab: .agents)`.
    var onTap: () -> Void = { }

    private let maxDots = 5

    private var liveSessions: [AgentSession] {
        store.orderedSessions.filter { $0.state != .ended }
    }

    var body: some View {
        let sessions = liveSessions
        if !sessions.isEmpty {
            // A sparkle glyph reads as "AI agents"; a bare red dot beside the
            // camera housing reads as a recording light.
            HStack(spacing: 3) {
                AgentWingGlyph(state: mostUrgentState(sessions))
                if sessions.count > 1 {
                    Text("\(sessions.count)")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 7)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .transition(.opacity.combined(with: .scale(scale: 0.6)))
            .help(wingHelp(sessions))
        }
    }

    private func mostUrgentState(_ sessions: [AgentSession]) -> AgentSessionState {
        if let urgent = sessions.first(where: { $0.state.needsAttention })?.state { return urgent }
        if let busy = sessions.first(where: { $0.state == .runningTool })?.state { return busy }
        if let working = sessions.first(where: { $0.state == .working || $0.state == .compacting })?.state {
            return working
        }
        return sessions.first?.state ?? .idle
    }

    private func wingHelp(_ sessions: [AgentSession]) -> String {
        let attention = sessions.filter { $0.state.needsAttention }.count
        if attention > 0 {
            return "\(attention) agent session\(attention == 1 ? "" : "s") need\(attention == 1 ? "s" : "") attention"
        }
        return "\(sessions.count) live agent session\(sessions.count == 1 ? "" : "s")"
    }
}

/// Sparkle glyph tinted by the aggregate session state; pulses (and gains a
/// soft halo) when a session needs attention, breathes gently while working.
private struct AgentWingGlyph: View {
    let state: AgentSessionState

    @State private var pulsing = false

    var body: some View {
        let color = AgentUIFormat.stateColor(state)
        Image(systemName: "sparkle")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .shadow(color: state.needsAttention ? color.opacity(0.8) : .clear, radius: 3)
            .scaleEffect(pulsing ? 1.25 : 1)
            .opacity(pulsing ? 1 : (state.needsAttention || state == .working || state == .runningTool ? 0.85 : 0.6))
            .onAppear { restart() }
            .onChange(of: state) { restart() }
    }

    private func restart() {
        pulsing = false
        guard state.needsAttention else { return }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }
}
