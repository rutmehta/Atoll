import SwiftUI

/// 30-day spend dashboard: stat tiles (total + today), pure-SwiftUI stacked
/// bar chart with hover tooltip (day total + per-model breakdown) and a model
/// color legend.
struct AgentCostDashboard: View {
    @ObservedObject private var scanner = AgentCostScanner.shared
    @State private var hoveredDayKey: String?

    private static let palette: [Color] = [
        .blue, .purple, .orange, .green, .pink, .teal, .yellow, .red, .indigo, .mint,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statRow
            if scanner.days.isEmpty || scanner.totalTokens30 == 0 {
                emptyState
            } else {
                chart
                legend
            }
        }
        .onAppear { scanner.rescan() }
    }

    // MARK: Stat tiles

    private var statRow: some View {
        HStack(spacing: 8) {
            statTile(title: "Last 30 days",
                     value: AgentUIFormat.money(scanner.totalUSD30),
                     sub: "\(AgentUIFormat.tokens(scanner.totalTokens30)) tokens")
            statTile(title: "Today",
                     value: AgentUIFormat.money(scanner.todayUSD),
                     sub: scanner.days.last.map { "\(AgentUIFormat.tokens($0.tokens)) tokens" } ?? "")
            Spacer()
            if scanner.scanning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            }
            Button {
                scanner.rescan(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .foregroundStyle(Color(white: 0.75))
            }
            .buttonStyle(.plain)
            .help("Rescan transcripts")
        }
    }

    private func statTile(title: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Color(white: 0.5))
            Text(value)
                .font(.system(size: 16, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
            Text(sub)
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(Color(white: 0.45))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    // MARK: Chart

    private var maxDayUSD: Double {
        max(scanner.days.map(\.totalUSD).max() ?? 0, 0.0001)
    }

    private var hoveredDay: AgentDayCost? {
        guard let key = hoveredDayKey else { return nil }
        return scanner.days.first { $0.dayKey == key }
    }

    private var chart: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: 2.5) {
                    ForEach(scanner.days) { day in
                        bar(day, chartHeight: geo.size.height)
                            .frame(maxWidth: .infinity)
                            .onHover { inside in
                                if inside {
                                    hoveredDayKey = day.dayKey
                                } else if hoveredDayKey == day.dayKey {
                                    hoveredDayKey = nil
                                }
                            }
                    }
                }
            }
            .frame(height: 110)
            .overlay(alignment: .top) {
                if let day = hoveredDay {
                    tooltip(day)
                        .transition(.opacity)
                }
            }
            axisLabels
        }
    }

    @ViewBuilder
    private func bar(_ day: AgentDayCost, chartHeight: CGFloat) -> some View {
        let total = day.totalUSD
        let height = total <= 0 ? 2 : max(3, chartHeight * CGFloat(total / maxDayUSD))
        let hovered = hoveredDayKey == day.dayKey

        VStack(spacing: 0) {
            if total > 0 {
                // Stacked per-model segments, biggest spenders at the bottom.
                ForEach(segmentModels(day), id: \.self) { model in
                    Rectangle()
                        .fill(color(for: model))
                        .frame(height: height * CGFloat((day.perModelUSD[model] ?? 0) / total))
                }
            } else {
                Rectangle().fill(Color.white.opacity(0.08))
            }
        }
        .frame(height: height)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .opacity(hovered ? 1 : 0.85)
        .scaleEffect(x: 1, y: hovered ? 1.03 : 1, anchor: .bottom)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    /// Models for a day ordered by the global legend order (stable stacking).
    private func segmentModels(_ day: AgentDayCost) -> [String] {
        scanner.modelsSeen.filter { (day.perModelUSD[$0] ?? 0) > 0 }
    }

    private func tooltip(_ day: AgentDayCost) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(day.day, format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                Text(AgentUIFormat.money(day.totalUSD))
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                Text("\(AgentUIFormat.tokens(day.tokens)) tok")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(Color(white: 0.55))
            }
            ForEach(segmentModels(day).prefix(5), id: \.self) { model in
                HStack(spacing: 4) {
                    Circle().fill(color(for: model)).frame(width: 5, height: 5)
                    Text(shortModelName(model))
                        .font(.system(size: 9))
                        .foregroundStyle(Color(white: 0.75))
                    Spacer(minLength: 6)
                    Text(AgentUIFormat.money(day.perModelUSD[model] ?? 0))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(Color(white: 0.75))
                }
            }
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
        )
        .fixedSize()
        .allowsHitTesting(false)
    }

    private var axisLabels: some View {
        HStack {
            if let first = scanner.days.first {
                Text(first.day, format: .dateTime.month(.abbreviated).day())
            }
            Spacer()
            Text("Today")
        }
        .font(.system(size: 8.5))
        .foregroundStyle(Color(white: 0.42))
    }

    // MARK: Legend

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(scanner.modelsSeen.prefix(6), id: \.self) { model in
                    HStack(spacing: 4) {
                        Circle().fill(color(for: model)).frame(width: 6, height: 6)
                        Text(shortModelName(model))
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color(white: 0.65))
                    }
                }
                if scanner.modelsSeen.count > 6 {
                    Text("+\(scanner.modelsSeen.count - 6) more")
                        .font(.system(size: 9))
                        .foregroundStyle(Color(white: 0.45))
                }
            }
        }
        .frame(height: 14)
    }

    private func color(for model: String) -> Color {
        guard let index = scanner.modelsSeen.firstIndex(of: model) else {
            return Color(white: 0.5)
        }
        return Self.palette[index % Self.palette.count]
    }

    /// "claude-sonnet-4-5-20250929" → "sonnet-4-5"; "gpt-5.1-codex" stays.
    private func shortModelName(_ model: String) -> String {
        var name = model
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        name = name.replacingOccurrences(of: "claude-", with: "")
        // Strip trailing -YYYYMMDD date stamps.
        if name.count > 9 {
            let suffix = name.suffix(9)
            if suffix.first == "-", suffix.dropFirst().allSatisfy(\.isNumber) {
                name = String(name.dropLast(9))
            }
        }
        return name
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 22))
                .foregroundStyle(Color(white: 0.4))
            Text(scanner.scanning ? "Scanning transcripts…" : "No cost data yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(white: 0.7))
            Text("Costs are computed locally from Claude Code and Codex transcripts.")
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.5))
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
