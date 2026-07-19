import SwiftUI

/// The Timers widget for the open notch (Tools tab): a segmented
/// Timer | Stopwatch card designed for the black notch background.
struct TimersWidgetView: View {
    @ObservedObject private var manager = TimerManager.shared
    @AppStorage("timers.selectedMode") private var mode: TimersMode = .timer

    var body: some View {
        VStack(spacing: 10) {
            modePicker
            Group {
                switch mode {
                case .timer:
                    TimersCountdownPane(manager: manager)
                case .stopwatch:
                    TimersStopwatchPane(manager: manager)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 158)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .frame(minWidth: 220, maxWidth: 340)
        .foregroundStyle(.white)
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(TimersMode.allCases) { candidate in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        mode = candidate
                    }
                } label: {
                    Text(candidate.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(mode == candidate ? .white : .white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(mode == candidate ? Color.white.opacity(0.16) : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

// MARK: - Mode

private enum TimersMode: String, CaseIterable, Identifiable {
    case timer
    case stopwatch

    var id: String { rawValue }
    var title: String {
        switch self {
        case .timer: return "Timer"
        case .stopwatch: return "Stopwatch"
        }
    }
}

// MARK: - Countdown pane

private struct TimersCountdownPane: View {
    @ObservedObject var manager: TimerManager

    private static let presetMinutes = [1, 5, 10, 25]

    var body: some View {
        switch manager.countdownPhase {
        case .idle:
            configureView
        case .running, .paused:
            activeView
        case .finished:
            finishedView
        }
    }

    // MARK: Idle — duration picker + presets

    private var configureView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                durationColumn(unit: "hr", value: hours) { adjustHours($0) }
                colon
                durationColumn(unit: "min", value: minutes) { adjustMinutes($0) }
                colon
                durationColumn(unit: "sec", value: seconds) { adjustSeconds($0) }
            }

            HStack(spacing: 6) {
                ForEach(Self.presetMinutes, id: \.self) { preset in
                    presetChip(minutes: preset)
                }
            }

            Button {
                manager.startCountdown()
            } label: {
                Label("Start", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.orange.opacity(canStart ? 0.85 : 0.25)))
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
        }
    }

    private var canStart: Bool { manager.configuredDuration >= 1 }

    private var colon: some View {
        Text(":")
            .font(.system(size: 20, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.35))
            .padding(.bottom, 12)
    }

    private func durationColumn(unit: String, value: Int, adjust: @escaping (Int) -> Void) -> some View {
        VStack(spacing: 1) {
            stepButton(systemImage: "chevron.up") { adjust(1) }
            Text(String(format: "%02d", value))
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(width: 40)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
            stepButton(systemImage: "chevron.down") { adjust(-1) }
            Text(unit)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private func stepButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 40, height: 13)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func presetChip(minutes preset: Int) -> some View {
        let isSelected = Int(manager.configuredDuration) == preset * 60
        return Button {
            manager.configuredDuration = TimeInterval(preset * 60)
        } label: {
            Text("\(preset)m")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(isSelected ? .white : .white.opacity(0.65))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(isSelected ? 0.2 : 0.08)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Duration math (wraps like a wheel)

    private var hours: Int { Int(manager.configuredDuration) / 3600 }
    private var minutes: Int { (Int(manager.configuredDuration) % 3600) / 60 }
    private var seconds: Int { Int(manager.configuredDuration) % 60 }

    private func adjustHours(_ delta: Int) {
        let wrapped = (hours + delta + 24) % 24
        manager.configuredDuration = TimeInterval(wrapped * 3600 + minutes * 60 + seconds)
    }

    private func adjustMinutes(_ delta: Int) {
        let wrapped = (minutes + delta + 60) % 60
        manager.configuredDuration = TimeInterval(hours * 3600 + wrapped * 60 + seconds)
    }

    private func adjustSeconds(_ delta: Int) {
        let wrapped = (seconds + delta + 60) % 60
        manager.configuredDuration = TimeInterval(hours * 3600 + minutes * 60 + wrapped)
    }

    // MARK: Running / paused — ring + controls

    private var activeView: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: manager.countdownProgress)
                    .stroke(
                        AngularGradient(
                            colors: [.orange, .yellow.opacity(0.9), .orange],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: manager.countdownProgress)
                VStack(spacing: 1) {
                    Text(TimersFormatting.countdown(manager.countdownRemaining))
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(manager.countdownPhase == .paused
                         ? "Paused"
                         : TimersFormatting.spoken(manager.countdownTotal))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(width: 104, height: 104)
            .opacity(manager.countdownPhase == .paused ? 0.65 : 1)

            HStack(spacing: 10) {
                capsuleButton(
                    title: "Cancel",
                    systemImage: "xmark",
                    tint: .white.opacity(0.7),
                    fill: Color.white.opacity(0.1)
                ) {
                    manager.cancelCountdown()
                }
                if manager.countdownPhase == .running {
                    capsuleButton(
                        title: "Pause",
                        systemImage: "pause.fill",
                        tint: .orange,
                        fill: Color.orange.opacity(0.22)
                    ) {
                        manager.pauseCountdown()
                    }
                } else {
                    capsuleButton(
                        title: "Resume",
                        systemImage: "play.fill",
                        tint: .orange,
                        fill: Color.orange.opacity(0.22)
                    ) {
                        manager.resumeCountdown()
                    }
                }
            }
        }
    }

    // MARK: Finished

    private var finishedView: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
                .symbolRenderingMode(.hierarchical)
            Text("Timer Done")
                .font(.system(size: 13, weight: .semibold))
            Text(TimersFormatting.spoken(manager.countdownTotal))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
            capsuleButton(
                title: "OK",
                systemImage: "checkmark",
                tint: .white,
                fill: Color.white.opacity(0.14)
            ) {
                manager.cancelCountdown()
            }
        }
    }

    private func capsuleButton(
        title: String,
        systemImage: String,
        tint: Color,
        fill: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Capsule().fill(fill))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Stopwatch pane

private struct TimersStopwatchPane: View {
    @ObservedObject var manager: TimerManager

    var body: some View {
        VStack(spacing: 12) {
            TimelineView(.animation(minimumInterval: 0.02, paused: !manager.stopwatchRunning)) { context in
                let elapsed = manager.stopwatchElapsed(at: context.date)
                VStack(spacing: 10) {
                    stopwatchDisplay(elapsed)
                    controls
                    lapsSection(elapsed: elapsed)
                }
            }
        }
    }

    // MARK: Display — big minutes:seconds with smaller dimmed centiseconds

    private func stopwatchDisplay(_ elapsed: TimeInterval) -> some View {
        let full = TimersFormatting.stopwatch(elapsed)
        let parts = full.split(separator: ".", maxSplits: 1)
        let main = String(parts.first ?? "00:00")
        let centi = parts.count > 1 ? String(parts[1]) : "00"
        return HStack(alignment: .lastTextBaseline, spacing: 1) {
            Text(main)
                .font(.system(size: 38, weight: .light, design: .rounded))
            Text(".\(centi)")
                .font(.system(size: 22, weight: .light, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
        }
        .monospacedDigit()
        .frame(height: 44)
        .contentTransition(.numericText())
    }

    // MARK: Controls — round Lap/Reset (left) and Start/Stop (right)

    private var controls: some View {
        HStack {
            if manager.stopwatchRunning {
                circleButton(title: "Lap", tint: .white.opacity(0.85)) {
                    manager.recordLap()
                }
            } else if manager.stopwatchElapsed > 0 {
                circleButton(title: "Reset", tint: .white.opacity(0.85)) {
                    manager.resetStopwatch()
                }
            } else {
                circleButton(title: "Lap", tint: .white.opacity(0.3)) {}
                    .disabled(true)
            }
            Spacer()
            if manager.stopwatchRunning {
                circleButton(title: "Stop", tint: .red) {
                    manager.pauseStopwatch()
                }
            } else {
                circleButton(title: manager.stopwatchElapsed > 0 ? "Resume" : "Start", tint: .green) {
                    manager.startStopwatch()
                }
            }
        }
        .padding(.horizontal, 34)
    }

    private func circleButton(title: String, tint: Color, action: @escaping () -> Void) -> some View {
        StopwatchCircleButton(title: title, tint: tint, action: action)
    }

    // MARK: Laps — live current lap on top, best/worst colored

    @ViewBuilder
    private func lapsSection(elapsed: TimeInterval) -> some View {
        if manager.laps.isEmpty && !manager.stopwatchRunning {
            Spacer(minLength: 0)
        } else {
            let laps = manager.laps
            // Best/worst by delta, iOS-style, only meaningful with 2+ laps.
            let deltas = laps.map(\.delta)
            let best = laps.count >= 2 ? deltas.min() : nil
            let worst = laps.count >= 2 ? deltas.max() : nil

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if manager.stopwatchRunning || elapsed > 0 {
                        lapRow(
                            label: "Lap \(laps.count + 1)",
                            delta: elapsed - (laps.first?.total ?? 0),
                            total: elapsed,
                            deltaColor: .white.opacity(0.45),
                            live: true
                        )
                    }
                    // `laps` is already newest-first (inserted at index 0).
                    ForEach(laps) { lap in
                        lapRow(
                            label: "Lap \(lap.index)",
                            delta: lap.delta,
                            total: lap.total,
                            deltaColor: lap.delta == best ? .green
                                : lap.delta == worst ? .red
                                : .white.opacity(0.7),
                            live: false
                        )
                    }
                }
            }
            .frame(maxHeight: 96)
        }
    }

    private func lapRow(
        label: String,
        delta: TimeInterval,
        total: TimeInterval,
        deltaColor: Color,
        live: Bool
    ) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.white.opacity(live ? 0.35 : 0.5))
            Spacer()
            Text("+\(TimersFormatting.stopwatch(delta))")
                .foregroundStyle(live ? .white.opacity(0.35) : deltaColor)
            Spacer()
            Text(TimersFormatting.stopwatch(total))
                .foregroundStyle(.white.opacity(live ? 0.5 : 0.85))
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 3.5)
        .padding(.horizontal, 2)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }
}

/// iOS-style round stopwatch button with hover/press feedback.
private struct StopwatchCircleButton: View {
    let title: String
    let tint: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .frame(width: 54, height: 54)
                .background(Circle().fill(tint.opacity(hovering ? 0.26 : 0.16)))
                .overlay(Circle().stroke(tint.opacity(0.3), lineWidth: 1))
                .contentShape(Circle())
                .scaleEffect(hovering ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hovering)
    }
}
