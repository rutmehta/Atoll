import SwiftUI

/// The Timers widget for the open notch (Tools tab): Timer | Stopwatch | Pomodoro.
///
/// Every mode shares one skeleton — mode picker, a fixed-height display slot,
/// a fixed-height controls row, then a flexible detail area — so nothing jumps
/// around when switching modes.
struct TimersWidgetView: View {
    @ObservedObject private var manager = TimerManager.shared
    @AppStorage("timers.selectedMode") private var mode: TimersMode = .timer

    private static let displayHeight: CGFloat = 132
    private static let controlsHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: 12) {
            modePicker

            display
                .frame(maxWidth: .infinity)
                .frame(height: Self.displayHeight)

            controls
                .frame(maxWidth: .infinity)
                .frame(height: Self.controlsHeight)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .frame(minWidth: 260, maxWidth: 360)
        .foregroundStyle(.white)
    }

    // MARK: Mode picker

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(TimersMode.allCases) { candidate in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        mode = candidate
                    }
                } label: {
                    Text(candidate.title)
                        .font(.system(size: 11.5, weight: .medium))
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

    // MARK: Slots

    @ViewBuilder
    private var display: some View {
        switch mode {
        case .timer: TimerDisplay(manager: manager)
        case .stopwatch: StopwatchDisplay(manager: manager)
        case .pomodoro: PomodoroDisplay(manager: manager)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch mode {
        case .timer: TimerControls(manager: manager)
        case .stopwatch: StopwatchControls(manager: manager)
        case .pomodoro: PomodoroControls(manager: manager)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch mode {
        case .stopwatch: StopwatchLaps(manager: manager)
        case .timer, .pomodoro: Spacer(minLength: 0)
        }
    }
}

// MARK: - Mode

private enum TimersMode: String, CaseIterable, Identifiable {
    case timer
    case stopwatch
    case pomodoro

    var id: String { rawValue }
    var title: String {
        switch self {
        case .timer: return "Timer"
        case .stopwatch: return "Stopwatch"
        case .pomodoro: return "Pomodoro"
        }
    }
}

// MARK: - Shared ring

/// Depleting progress ring, iOS Timers style. 116 pt.
private struct TimersRing<Center: View>: View {
    var remainingFraction: Double
    var tint: Color
    var dimmed = false
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0, min(1, remainingFraction)))
                .stroke(
                    AngularGradient(colors: [tint, tint.opacity(0.65), tint], center: .center),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: remainingFraction)
            center()
        }
        .frame(width: 116, height: 116)
        .opacity(dimmed ? 0.65 : 1)
        .animation(.easeOut(duration: 0.2), value: dimmed)
    }
}

/// iOS-style round action button shared by every mode.
private struct TimersCircleButton: View {
    let title: String
    let tint: Color
    var size: CGFloat = 54
    var disabled = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(disabled ? tint.opacity(0.35) : tint)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .frame(width: size, height: size)
                .background(Circle().fill(tint.opacity(disabled ? 0.07 : (hovering ? 0.26 : 0.16))))
                .overlay(Circle().stroke(tint.opacity(disabled ? 0.12 : 0.3), lineWidth: 1))
                .contentShape(Circle())
                .scaleEffect(hovering && !disabled ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hovering)
    }
}

// MARK: - Timer mode

private struct TimerDisplay: View {
    @ObservedObject var manager: TimerManager

    private static let presetMinutes = [1, 5, 10, 25]

    var body: some View {
        switch manager.countdownPhase {
        case .idle:
            configure
        case .running, .paused:
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                TimersRing(
                    remainingFraction: fraction(at: context.date),
                    tint: .orange,
                    dimmed: manager.countdownPhase == .paused
                ) {
                    VStack(spacing: 1) {
                        Text(TimersFormatting.countdown(manager.countdownRemaining(at: context.date)))
                            .font(.system(size: 22, weight: .medium, design: .rounded))
                            .monospacedDigit()
                        Text(manager.countdownPhase == .paused
                             ? "Paused"
                             : TimersFormatting.spoken(manager.countdownTotal))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
        case .finished:
            TimersRing(remainingFraction: 1, tint: .green) {
                VStack(spacing: 2) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.green)
                    Text("Done")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    private func fraction(at date: Date) -> Double {
        guard manager.countdownTotal > 0 else { return 0 }
        return manager.countdownRemaining(at: date) / manager.countdownTotal
    }

    private var configure: some View {
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
        }
    }

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
}

private struct TimerControls: View {
    @ObservedObject var manager: TimerManager

    var body: some View {
        HStack {
            switch manager.countdownPhase {
            case .idle:
                TimersCircleButton(title: "Reset", tint: .white.opacity(0.85), disabled: true) {}
                Spacer()
                TimersCircleButton(
                    title: "Start", tint: .green,
                    disabled: manager.configuredDuration < 1
                ) { manager.startCountdown() }
            case .running:
                TimersCircleButton(title: "Cancel", tint: .white.opacity(0.85)) {
                    manager.cancelCountdown()
                }
                Spacer()
                TimersCircleButton(title: "Pause", tint: .orange) { manager.pauseCountdown() }
            case .paused:
                TimersCircleButton(title: "Cancel", tint: .white.opacity(0.85)) {
                    manager.cancelCountdown()
                }
                Spacer()
                TimersCircleButton(title: "Resume", tint: .green) { manager.resumeCountdown() }
            case .finished:
                TimersCircleButton(title: "Reset", tint: .white.opacity(0.85), disabled: true) {}
                Spacer()
                TimersCircleButton(title: "OK", tint: .green) { manager.cancelCountdown() }
            }
        }
        .padding(.horizontal, 34)
    }
}

// MARK: - Stopwatch mode

private struct StopwatchDisplay: View {
    @ObservedObject var manager: TimerManager

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.02, paused: !manager.stopwatchRunning)) { context in
            let full = TimersFormatting.stopwatch(manager.stopwatchElapsed(at: context.date))
            let parts = full.split(separator: ".", maxSplits: 1)
            HStack(alignment: .lastTextBaseline, spacing: 1) {
                Text(String(parts.first ?? "00:00"))
                    .font(.system(size: 40, weight: .light, design: .rounded))
                Text(".\(parts.count > 1 ? String(parts[1]) : "00")")
                    .font(.system(size: 23, weight: .light, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .monospacedDigit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct StopwatchControls: View {
    @ObservedObject var manager: TimerManager

    var body: some View {
        HStack {
            if manager.stopwatchRunning {
                TimersCircleButton(title: "Lap", tint: .white.opacity(0.85)) { manager.recordLap() }
            } else if manager.stopwatchElapsed > 0 {
                TimersCircleButton(title: "Reset", tint: .white.opacity(0.85)) { manager.resetStopwatch() }
            } else {
                TimersCircleButton(title: "Lap", tint: .white.opacity(0.85), disabled: true) {}
            }
            Spacer()
            if manager.stopwatchRunning {
                TimersCircleButton(title: "Stop", tint: .red) { manager.pauseStopwatch() }
            } else {
                TimersCircleButton(
                    title: manager.stopwatchElapsed > 0 ? "Resume" : "Start",
                    tint: .green
                ) { manager.startStopwatch() }
            }
        }
        .padding(.horizontal, 34)
    }
}

private struct StopwatchLaps: View {
    @ObservedObject var manager: TimerManager

    var body: some View {
        let laps = manager.laps
        if laps.isEmpty && !manager.stopwatchRunning && manager.stopwatchElapsed == 0 {
            Spacer(minLength: 0)
        } else {
            let deltas = laps.map(\.delta)
            let best = laps.count >= 2 ? deltas.min() : nil
            let worst = laps.count >= 2 ? deltas.max() : nil

            TimelineView(.periodic(from: .now, by: manager.stopwatchRunning ? 0.5 : 3600)) { context in
                let elapsed = manager.stopwatchElapsed(at: context.date)
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        lapRow(
                            label: "Lap \(laps.count + 1)",
                            delta: elapsed - (laps.first?.total ?? 0),
                            total: elapsed,
                            deltaColor: .white.opacity(0.35),
                            live: true
                        )
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
            }
        }
    }

    private func lapRow(
        label: String, delta: TimeInterval, total: TimeInterval,
        deltaColor: Color, live: Bool
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
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }
}

// MARK: - Pomodoro mode

private struct PomodoroDisplay: View {
    @ObservedObject var manager: TimerManager

    private var tint: Color {
        switch manager.pomodoroPhase {
        case .idle, .focus: return Color(red: 1.0, green: 0.36, blue: 0.30) // tomato
        case .shortBreak: return .green
        case .longBreak: return .mint
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let remaining = manager.isPomodoroActive
                ? manager.pomodoroRemaining(at: context.date)
                : TimeInterval(manager.pomodoroFocusMinutes * 60)
            let fraction = manager.isPomodoroActive && manager.pomodoroTotal > 0
                ? remaining / manager.pomodoroTotal
                : 1

            TimersRing(
                remainingFraction: fraction,
                tint: tint,
                dimmed: manager.isPomodoroActive && manager.pomodoroPaused
            ) {
                VStack(spacing: 2) {
                    Text(manager.pomodoroPhase == .idle ? "Focus" : manager.pomodoroPhase.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(tint)
                        .textCase(.uppercase)
                        .kerning(0.5)
                    Text(TimersFormatting.countdown(remaining))
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    sessionDots
                }
            }
        }
    }

    /// One dot per focus session in the cycle; filled = completed.
    private var sessionDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(1, manager.pomodoroSessionsPerCycle), id: \.self) { index in
                Circle()
                    .fill(index < manager.pomodoroCompletedFocus
                          ? tint
                          : Color.white.opacity(0.18))
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.top, 2)
    }
}

private struct PomodoroControls: View {
    @ObservedObject var manager: TimerManager

    var body: some View {
        HStack {
            TimersCircleButton(
                title: "Reset", tint: .white.opacity(0.85), size: 48,
                disabled: !manager.isPomodoroActive
            ) { manager.resetPomodoro() }
            Spacer()
            if manager.isPomodoroRunning {
                TimersCircleButton(title: "Pause", tint: .orange, size: 48) {
                    manager.pausePomodoro()
                }
            } else if manager.isPomodoroActive {
                TimersCircleButton(title: "Resume", tint: .green, size: 48) {
                    manager.resumePomodoro()
                }
            } else {
                TimersCircleButton(title: "Start", tint: .green, size: 48) {
                    manager.startPomodoro()
                }
            }
            Spacer()
            TimersCircleButton(
                title: "Skip", tint: .white.opacity(0.85), size: 48,
                disabled: !manager.isPomodoroActive
            ) { manager.skipPomodoroPhase() }
        }
        .padding(.horizontal, 24)
    }
}
