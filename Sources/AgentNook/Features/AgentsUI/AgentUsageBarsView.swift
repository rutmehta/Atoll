import SwiftUI

/// Per-provider quota bars: 4 pt capsule (green < 50, amber < 80, red ≥ 80),
/// monospaced percentage, "Resets in Xh Ym", stale dimming and error/recovery
/// states with a Retry button.
struct AgentUsageBarsView: View {
    @ObservedObject private var usage = AgentUsageManager.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                providerCard(
                    provider: .claude,
                    data: usage.claudeUsage,
                    status: usage.claudeStatus)
                providerCard(
                    provider: .codex,
                    data: usage.codexUsage,
                    status: usage.codexStatus)
            }
            .padding(.bottom, 4)
        }
        .onAppear { usage.refreshIfNeeded() }
    }

    // MARK: Provider card

    @ViewBuilder
    private func providerCard(provider: AgentProvider,
                              data: AgentProviderUsage?,
                              status: AgentUsageStatus) -> some View {
        let stale = usage.isStale(provider)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AgentProviderGlyph(provider: provider, size: 12)
                Text(provider.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                if case .loading = status {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                }
                Spacer()
                if let data {
                    Text("Updated \(AgentUIFormat.relative(data.fetchedAt)) ago")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color(white: 0.45))
                }
                if stale || status.isError {
                    retryButton(provider)
                }
            }

            switch status {
            case .error(let message, let recovery):
                errorBlock(message: message, recovery: recovery)
            default:
                if let data, !data.windows.isEmpty {
                    ForEach(data.windows) { window in
                        windowRow(window, stale: stale)
                    }
                    if let credits = data.creditsBalance {
                        creditsRow(credits)
                    }
                    if case .stale(let message) = status {
                        Text(message)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.yellow.opacity(0.8))
                    }
                } else if case .loading = status {
                    Text("Loading usage…")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.5))
                } else {
                    Text("No usage data yet")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.5))
                }
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    // MARK: Rows

    private func windowRow(_ window: AgentUsageWindow, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3.5) {
            HStack(spacing: 6) {
                Text(window.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(white: 0.75))
                Spacer()
                if let resets = AgentUIFormat.resetsIn(window.resetsAt) {
                    Text(resets)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color(white: 0.45))
                }
                Text(String(format: "%.0f%%", window.percent))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(stale ? Color(white: 0.55) : barColor(window.percent))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(stale ? Color(white: 0.5) : barColor(window.percent))
                        .frame(width: max(4, geo.size.width * window.percent / 100))
                }
            }
            .frame(height: 4)
        }
        .opacity(stale ? 0.6 : 1)
    }

    private func creditsRow(_ credits: Double) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "creditcard")
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.55))
            Text("Credits")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(white: 0.75))
            Spacer()
            Text(String(format: "%.0f", credits))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
            Text(String(format: "≈ $%.2f", credits * 0.04))
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(Color(white: 0.45))
        }
    }

    private func errorBlock(message: String, recovery: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.yellow)
            Text(recovery)
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.55))
        }
    }

    private func retryButton(_ provider: AgentProvider) -> some View {
        Button {
            usage.retry(provider)
        } label: {
            Label("Retry", systemImage: "arrow.clockwise")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func barColor(_ percent: Double) -> Color {
        if percent >= 80 { return .red }
        if percent >= 50 { return .orange }
        return .green
    }
}
