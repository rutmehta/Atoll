import SwiftUI

/// Compact live-activity wing for the closed notch: a tiny depleting ring plus
/// the remaining countdown time. Renders nothing when no countdown is active,
/// so the integrator can compose it unconditionally (still recommended to gate
/// on `SettingsStore.timerLiveActivity`).
///
/// Sized for a wing next to the physical notch (~28-36 pt tall); it stretches
/// to whatever height the closed notch gives it.
struct TimerClosedWing: View {
    @ObservedObject private var manager = TimerManager.shared
    @State private var finishedPulse = false

    private var pomodoroTint: Color {
        switch manager.pomodoroPhase {
        case .idle, .focus: return Color(red: 1.0, green: 0.36, blue: 0.30)
        case .shortBreak: return .green
        case .longBreak: return .mint
        }
    }

    var body: some View {
        if manager.isCountdownActive {
            HStack(spacing: 5) {
                ring
                Text(TimersFormatting.countdown(manager.countdownRemaining))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(manager.countdownPhase == .paused ? .white.opacity(0.55) : .white)
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .opacity(finishedOpacity)
            .onChange(of: manager.countdownPhase) { _, phase in
                if phase == .finished {
                    withAnimation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true)) {
                        finishedPulse = true
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        finishedPulse = false
                    }
                }
            }
        } else if manager.isPomodoroActive {
            HStack(spacing: 5) {
                pomodoroRing
                Text(TimersFormatting.countdown(manager.pomodoroRemaining))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(manager.pomodoroPaused ? .white.opacity(0.55) : .white)
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
        }
    }

    private var pomodoroRing: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: manager.pomodoroTotal > 0
                      ? manager.pomodoroRemaining / manager.pomodoroTotal : 0)
                .stroke(pomodoroTint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: manager.pomodoroRemaining)
            if manager.pomodoroPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(pomodoroTint)
            }
        }
        .frame(width: 14, height: 14)
    }

    private var finishedOpacity: Double {
        manager.countdownPhase == .finished ? (finishedPulse ? 0.35 : 1) : 1
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: manager.countdownPhase == .finished ? 1 : manager.countdownProgress)
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: manager.countdownProgress)
            if manager.countdownPhase == .paused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 14, height: 14)
    }
}
