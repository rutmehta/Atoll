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
            HStack(spacing: 4) {
                ForEach(sessions.prefix(maxDots)) { session in
                    AgentWingDot(state: session.state)
                }
                if sessions.count > maxDots {
                    Text("+\(sessions.count - maxDots)")
                        .font(.system(size: 8, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color(white: 0.6))
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

    private func wingHelp(_ sessions: [AgentSession]) -> String {
        let attention = sessions.filter { $0.state.needsAttention }.count
        if attention > 0 {
            return "\(attention) agent session\(attention == 1 ? "" : "s") need\(attention == 1 ? "s" : "") attention"
        }
        return "\(sessions.count) live agent session\(sessions.count == 1 ? "" : "s")"
    }
}

/// A single 5 pt state dot with a red pulse animation when attention is needed.
private struct AgentWingDot: View {
    let state: AgentSessionState

    @State private var pulsing = false

    var body: some View {
        let color = AgentUIFormat.stateColor(state)
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.8), lineWidth: 1)
                    .scaleEffect(pulsing ? 2.6 : 1)
                    .opacity(pulsing ? 0 : 0.9)
            )
            .onAppear { restart() }
            .onChange(of: state) { restart() }
    }

    private func restart() {
        pulsing = false
        guard state.needsAttention else { return }
        withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) {
            pulsing = true
        }
    }
}
