import SwiftUI
import AppKit
import Combine
import UserNotifications

/// A single recorded stopwatch lap.
struct TimerLap: Identifiable, Equatable {
    let id = UUID()
    /// 1-based lap number (highest = most recent).
    let index: Int
    /// Total stopwatch time when the lap was recorded.
    let total: TimeInterval
    /// Time elapsed since the previous lap.
    let delta: TimeInterval
}

/// Countdown timer + stopwatch engine for the Timers widget.
///
/// Both clocks are driven by a single 0.5 s tick, but every published value is
/// recomputed from `Date` anchors so no drift ever accumulates. The running
/// countdown persists across relaunches via `@AppStorage` anchor dates, and the
/// completion notification is scheduled with a time-interval trigger up front so
/// it fires even if the app quits before the timer ends.
@MainActor
final class TimerManager: ObservableObject {
    static let shared = TimerManager()

    enum CountdownPhase: Equatable {
        case idle
        case running
        case paused
        case finished
    }

    // MARK: - Published state

    @Published private(set) var countdownPhase: CountdownPhase = .idle
    /// Seconds left on the countdown (recomputed from the end-date anchor).
    @Published private(set) var countdownRemaining: TimeInterval = 0
    /// Full duration of the countdown currently running/paused/finished.
    @Published private(set) var countdownTotal: TimeInterval = 0

    @Published private(set) var stopwatchRunning = false
    @Published private(set) var stopwatchElapsed: TimeInterval = 0
    /// Newest lap first.
    @Published private(set) var laps: [TimerLap] = []

    // MARK: Pomodoro

    enum PomodoroPhase: String {
        case idle
        case focus
        case shortBreak
        case longBreak

        var label: String {
            switch self {
            case .idle: return "Pomodoro"
            case .focus: return "Focus"
            case .shortBreak: return "Break"
            case .longBreak: return "Long Break"
            }
        }
    }

    @Published private(set) var pomodoroPhase: PomodoroPhase = .idle
    @Published private(set) var pomodoroPaused = false
    @Published private(set) var pomodoroRemaining: TimeInterval = 0
    @Published private(set) var pomodoroTotal: TimeInterval = 0
    /// Focus sessions completed in the current cycle (0..<sessionsPerCycle).
    @Published private(set) var pomodoroCompletedFocus = 0

    @Published private(set) var notificationAuthStatus: UNAuthorizationStatus = .notDetermined

    /// Called when a countdown completes while the auto-open setting is on.
    /// The integrator should set this to open the notch (e.g. `vm.open(tab: .tools)`).
    var onCountdownFinished: (() -> Void)?

    // MARK: - Settings (module-prefixed @AppStorage)

    /// Sounds offered in the completion-sound picker (system NSSound names + "None").
    static let completionSoundOptions = ["Glass", "Ping", "Hero", "Submarine", "Funk", "Purr", "Sosumi", "Basso", "None"]

    @AppStorage("timers.completionSound") var completionSoundName = "Glass" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("timers.autoOpenOnComplete") var autoOpenOnComplete = true {
        willSet { objectWillChange.send() }
    }
    @AppStorage("timers.pomodoroFocusMinutes") var pomodoroFocusMinutes = 25 {
        willSet { objectWillChange.send() }
    }
    @AppStorage("timers.pomodoroShortBreakMinutes") var pomodoroShortBreakMinutes = 5 {
        willSet { objectWillChange.send() }
    }
    @AppStorage("timers.pomodoroLongBreakMinutes") var pomodoroLongBreakMinutes = 15 {
        willSet { objectWillChange.send() }
    }
    @AppStorage("timers.pomodoroSessionsPerCycle") var pomodoroSessionsPerCycle = 4 {
        willSet { objectWillChange.send() }
    }
    @AppStorage("timers.pomodoroAutoAdvance") var pomodoroAutoAdvance = true {
        willSet { objectWillChange.send() }
    }

    // MARK: - Persistence anchors (@AppStorage)

    /// Unix epoch of the moment the running countdown completes; 0 when not running.
    @AppStorage("timers.endDateEpoch") private var storedEndDateEpoch: Double = 0
    /// Total duration of the persisted running/paused countdown.
    @AppStorage("timers.runningTotal") private var storedRunningTotal: Double = 0
    /// Remaining seconds of a paused countdown; 0 when not paused.
    @AppStorage("timers.pausedRemaining") private var storedPausedRemaining: Double = 0
    /// Last duration the user configured in the picker.
    @AppStorage("timers.configuredDuration") private var storedConfiguredDuration: Double = 300
    /// Pomodoro persistence: phase raw value ("idle" when inactive).
    @AppStorage("timers.pomodoroPhase") private var storedPomodoroPhase = "idle"
    @AppStorage("timers.pomodoroEndEpoch") private var storedPomodoroEndEpoch: Double = 0
    @AppStorage("timers.pomodoroPausedRemaining") private var storedPomodoroPausedRemaining: Double = 0
    @AppStorage("timers.pomodoroTotal") private var storedPomodoroTotal: Double = 0
    @AppStorage("timers.pomodoroCompletedFocus") private var storedPomodoroCompletedFocus = 0

    // MARK: - Private state

    private var countdownEndDate: Date?
    private var pomodoroEndDate: Date?
    private var tickTimer: Timer?
    private var completionTimer: Timer?
    private var pomodoroCompletionTimer: Timer?
    private var finishResetTask: Task<Void, Never>?
    private var stopwatchStartDate: Date?
    private var stopwatchAccumulated: TimeInterval = 0
    private var playingSound: NSSound?

    private let notificationIdentifier = "atoll.timers.countdown"
    private let pomodoroNotificationIdentifier = "atoll.timers.pomodoro"

    private init() {
        restorePersistedCountdown()
        restorePersistedPomodoro()
    }

    // MARK: - Configured duration (picker binding surface)

    /// Duration currently dialed into the picker, clamped to 0...(24 h - 1 s).
    var configuredDuration: TimeInterval {
        get { storedConfiguredDuration }
        set {
            objectWillChange.send()
            storedConfiguredDuration = min(max(0, newValue), 24 * 3600 - 1)
        }
    }

    // MARK: - Countdown controls

    var isCountdownActive: Bool { countdownPhase != .idle }

    /// Fraction of the countdown still remaining (1 → just started, 0 → done).
    var countdownProgress: Double {
        guard countdownTotal > 0 else { return 0 }
        return min(1, max(0, countdownRemaining / countdownTotal))
    }

    func startCountdown() {
        let duration = configuredDuration
        guard duration >= 1, countdownPhase == .idle || countdownPhase == .finished else { return }
        finishResetTask?.cancel()

        let end = Date().addingTimeInterval(duration)
        countdownEndDate = end
        countdownTotal = duration
        countdownRemaining = duration
        countdownPhase = .running

        storedEndDateEpoch = end.timeIntervalSince1970
        storedRunningTotal = duration
        storedPausedRemaining = 0

        scheduleCompletionTimer(at: end)
        scheduleCompletionNotification()
        updateTickTimer()
    }

    func pauseCountdown() {
        guard countdownPhase == .running, let end = countdownEndDate else { return }
        let remaining = max(0, end.timeIntervalSinceNow)
        countdownEndDate = nil
        countdownRemaining = remaining
        countdownPhase = .paused

        storedEndDateEpoch = 0
        storedPausedRemaining = remaining

        completionTimer?.invalidate()
        completionTimer = nil
        removePendingCompletionNotification()
        updateTickTimer()
    }

    func resumeCountdown() {
        guard countdownPhase == .paused, countdownRemaining > 0 else { return }
        let end = Date().addingTimeInterval(countdownRemaining)
        countdownEndDate = end
        countdownPhase = .running

        storedEndDateEpoch = end.timeIntervalSince1970
        storedPausedRemaining = 0

        scheduleCompletionTimer(at: end)
        scheduleCompletionNotification()
        updateTickTimer()
    }

    func cancelCountdown() {
        guard countdownPhase != .idle else { return }
        finishResetTask?.cancel()
        countdownEndDate = nil
        countdownPhase = .idle
        countdownRemaining = 0
        countdownTotal = 0

        clearPersistedCountdown()
        completionTimer?.invalidate()
        completionTimer = nil
        removePendingCompletionNotification()
        updateTickTimer()
    }

    /// Remaining time computed against an arbitrary date (for TimelineView rendering).
    func countdownRemaining(at date: Date) -> TimeInterval {
        if countdownPhase == .running, let end = countdownEndDate {
            return max(0, end.timeIntervalSince(date))
        }
        return countdownRemaining
    }

    // MARK: - Stopwatch controls

    func startStopwatch() {
        guard !stopwatchRunning else { return }
        stopwatchStartDate = Date()
        stopwatchRunning = true
        updateTickTimer()
    }

    func pauseStopwatch() {
        guard stopwatchRunning else { return }
        stopwatchAccumulated = stopwatchElapsed(at: Date())
        stopwatchStartDate = nil
        stopwatchRunning = false
        stopwatchElapsed = stopwatchAccumulated
        updateTickTimer()
    }

    func toggleStopwatch() {
        stopwatchRunning ? pauseStopwatch() : startStopwatch()
    }

    func resetStopwatch() {
        stopwatchStartDate = nil
        stopwatchRunning = false
        stopwatchAccumulated = 0
        stopwatchElapsed = 0
        laps.removeAll()
        updateTickTimer()
    }

    func recordLap() {
        guard stopwatchRunning else { return }
        let total = stopwatchElapsed(at: Date())
        let delta = total - (laps.first?.total ?? 0)
        laps.insert(TimerLap(index: laps.count + 1, total: total, delta: delta), at: 0)
    }

    /// Elapsed time computed against an arbitrary date (for TimelineView rendering).
    func stopwatchElapsed(at date: Date) -> TimeInterval {
        if stopwatchRunning, let start = stopwatchStartDate {
            return stopwatchAccumulated + max(0, date.timeIntervalSince(start))
        }
        return stopwatchAccumulated
    }

    // MARK: - Pomodoro controls

    var isPomodoroActive: Bool { pomodoroPhase != .idle }
    var isPomodoroRunning: Bool { isPomodoroActive && !pomodoroPaused }

    var pomodoroProgress: Double {
        guard pomodoroTotal > 0 else { return 0 }
        return min(1, max(0, 1 - pomodoroRemaining / pomodoroTotal))
    }

    private func pomodoroDuration(for phase: PomodoroPhase) -> TimeInterval {
        switch phase {
        case .idle: return 0
        case .focus: return TimeInterval(max(1, pomodoroFocusMinutes) * 60)
        case .shortBreak: return TimeInterval(max(1, pomodoroShortBreakMinutes) * 60)
        case .longBreak: return TimeInterval(max(1, pomodoroLongBreakMinutes) * 60)
        }
    }

    func startPomodoro() {
        if pomodoroPhase == .idle {
            pomodoroCompletedFocus = 0
            beginPomodoroPhase(.focus)
        } else if pomodoroPaused {
            resumePomodoro()
        }
    }

    func pausePomodoro() {
        guard isPomodoroRunning, let end = pomodoroEndDate else { return }
        pomodoroRemaining = max(0, end.timeIntervalSinceNow)
        pomodoroEndDate = nil
        pomodoroPaused = true

        storedPomodoroEndEpoch = 0
        storedPomodoroPausedRemaining = pomodoroRemaining

        pomodoroCompletionTimer?.invalidate()
        pomodoroCompletionTimer = nil
        removePendingNotification(pomodoroNotificationIdentifier)
        updateTickTimer()
    }

    func resumePomodoro() {
        guard isPomodoroActive, pomodoroPaused, pomodoroRemaining > 0 else { return }
        let end = Date().addingTimeInterval(pomodoroRemaining)
        pomodoroEndDate = end
        pomodoroPaused = false

        storedPomodoroEndEpoch = end.timeIntervalSince1970
        storedPomodoroPausedRemaining = 0

        schedulePomodoroCompletionTimer(at: end)
        schedulePomodoroNotification()
        updateTickTimer()
    }

    func resetPomodoro() {
        pomodoroPhase = .idle
        pomodoroPaused = false
        pomodoroRemaining = 0
        pomodoroTotal = 0
        pomodoroCompletedFocus = 0
        pomodoroEndDate = nil

        clearPersistedPomodoro()
        pomodoroCompletionTimer?.invalidate()
        pomodoroCompletionTimer = nil
        removePendingNotification(pomodoroNotificationIdentifier)
        updateTickTimer()
    }

    /// Skip straight to the next phase (no sound — user-initiated).
    func skipPomodoroPhase() {
        guard isPomodoroActive else { return }
        advancePomodoro(announce: false)
    }

    /// Remaining time computed against an arbitrary date (for TimelineView rendering).
    func pomodoroRemaining(at date: Date) -> TimeInterval {
        if isPomodoroRunning, let end = pomodoroEndDate {
            return max(0, end.timeIntervalSince(date))
        }
        return pomodoroRemaining
    }

    private func beginPomodoroPhase(_ phase: PomodoroPhase, paused: Bool = false) {
        let duration = pomodoroDuration(for: phase)
        pomodoroPhase = phase
        pomodoroTotal = duration
        pomodoroRemaining = duration
        pomodoroPaused = paused

        storedPomodoroPhase = phase.rawValue
        storedPomodoroTotal = duration
        storedPomodoroCompletedFocus = pomodoroCompletedFocus

        if paused {
            pomodoroEndDate = nil
            storedPomodoroEndEpoch = 0
            storedPomodoroPausedRemaining = duration
            pomodoroCompletionTimer?.invalidate()
            pomodoroCompletionTimer = nil
        } else {
            let end = Date().addingTimeInterval(duration)
            pomodoroEndDate = end
            storedPomodoroEndEpoch = end.timeIntervalSince1970
            storedPomodoroPausedRemaining = 0
            schedulePomodoroCompletionTimer(at: end)
            schedulePomodoroNotification()
        }
        updateTickTimer()
    }

    private func advancePomodoro(announce: Bool) {
        let next: PomodoroPhase
        if pomodoroPhase == .focus {
            pomodoroCompletedFocus += 1
            let cycle = max(1, pomodoroSessionsPerCycle)
            next = pomodoroCompletedFocus % cycle == 0 ? .longBreak : .shortBreak
        } else {
            if pomodoroCompletedFocus >= max(1, pomodoroSessionsPerCycle) {
                pomodoroCompletedFocus = 0
            }
            next = .focus
        }
        if announce {
            playCompletionSound()
        }
        removePendingNotification(pomodoroNotificationIdentifier)
        // Auto-advance starts the next phase running; otherwise it waits paused
        // at the top of the next phase for an explicit resume.
        beginPomodoroPhase(next, paused: !pomodoroAutoAdvance)
    }

    private func completePomodoroPhase() {
        guard isPomodoroRunning else { return }
        advancePomodoro(announce: true)
    }

    // MARK: - Sounds

    func playCompletionSound() {
        play(soundNamed: completionSoundName)
    }

    /// Used by the settings view to audition a sound.
    func previewSound(named name: String) {
        play(soundNamed: name)
    }

    private func play(soundNamed name: String) {
        guard name != "None" else { return }
        playingSound?.stop()
        guard let sound = NSSound(named: name) else { return }
        playingSound = sound
        sound.play()
    }

    // MARK: - Notifications

    /// UNUserNotificationCenter crashes when the process has no bundle
    /// (e.g. bare `swift run`); everything notification-related is gated on this.
    var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func refreshNotificationStatus() async {
        guard notificationsAvailable else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAuthStatus = settings.authorizationStatus
    }

    /// Requests notification permission (used by the settings view's enable button).
    func requestNotificationPermission() async {
        _ = await ensureNotificationAuthorization()
    }

    /// Lazily requests authorization the first time it is needed.
    private func ensureNotificationAuthorization() async -> Bool {
        guard notificationsAvailable else { return false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            notificationAuthStatus = settings.authorizationStatus
            return true
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            await refreshNotificationStatus()
            return granted
        default:
            notificationAuthStatus = settings.authorizationStatus
            return false
        }
    }

    /// Schedules the completion banner with a time-interval trigger so it still
    /// fires if the app quits before the countdown ends. The audible part is the
    /// in-app NSSound, so the banner itself is silent.
    private func scheduleCompletionNotification() {
        guard notificationsAvailable else { return }
        Task { [weak self] in
            guard let self else { return }
            guard await self.ensureNotificationAuthorization() else { return }
            // Re-check state: the user may have paused/cancelled while the
            // authorization prompt was up.
            guard self.countdownPhase == .running, let end = self.countdownEndDate else { return }
            let interval = end.timeIntervalSinceNow
            guard interval >= 1 else { return }

            let content = UNMutableNotificationContent()
            content.title = "Timer Done"
            content.body = "Your \(TimersFormatting.spoken(self.countdownTotal)) timer finished."
            content.sound = nil

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(
                identifier: self.notificationIdentifier,
                content: content,
                trigger: trigger
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private func removePendingCompletionNotification() {
        removePendingNotification(notificationIdentifier)
    }

    private func removePendingNotification(_ identifier: String) {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// Pre-scheduled banner for the current pomodoro phase's end.
    private func schedulePomodoroNotification() {
        guard notificationsAvailable else { return }
        Task { [weak self] in
            guard let self else { return }
            guard await self.ensureNotificationAuthorization() else { return }
            guard self.isPomodoroRunning, let end = self.pomodoroEndDate else { return }
            let interval = end.timeIntervalSinceNow
            guard interval >= 1 else { return }

            let content = UNMutableNotificationContent()
            switch self.pomodoroPhase {
            case .focus:
                content.title = "Focus session done"
                content.body = "Time for a break."
            case .shortBreak, .longBreak:
                content.title = "Break's over"
                content.body = "Back to focus."
            case .idle:
                return
            }
            content.sound = nil

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: self.pomodoroNotificationIdentifier,
                content: content,
                trigger: trigger
            ))
        }
    }

    // MARK: - Tick engine

    private func updateTickTimer() {
        let needed = countdownPhase == .running || stopwatchRunning || isPomodoroRunning
        if needed {
            guard tickTimer == nil else { return }
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        } else {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    private func tick() {
        let now = Date()
        if countdownPhase == .running {
            let remaining = countdownRemaining(at: now)
            countdownRemaining = remaining
            if remaining <= 0.01 {
                completeCountdown()
            }
        }
        if stopwatchRunning {
            stopwatchElapsed = stopwatchElapsed(at: now)
        }
        if isPomodoroRunning {
            let remaining = pomodoroRemaining(at: now)
            pomodoroRemaining = remaining
            if remaining <= 0.01 {
                completePomodoroPhase()
            }
        }
    }

    /// One-shot timer at the pomodoro phase boundary (same rationale as the
    /// countdown's completion timer).
    private func schedulePomodoroCompletionTimer(at endDate: Date) {
        pomodoroCompletionTimer?.invalidate()
        let timer = Timer(fire: endDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pomodoroCompletionTimer = timer
    }

    /// One-shot timer at the exact end date so completion isn't quantized to the
    /// 0.5 s tick.
    private func scheduleCompletionTimer(at endDate: Date) {
        completionTimer?.invalidate()
        let timer = Timer(fire: endDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        completionTimer = timer
    }

    private func completeCountdown() {
        guard countdownPhase == .running else { return }
        countdownPhase = .finished
        countdownRemaining = 0
        countdownEndDate = nil

        clearPersistedCountdown()
        completionTimer?.invalidate()
        completionTimer = nil
        updateTickTimer()

        playCompletionSound()
        if autoOpenOnComplete {
            onCountdownFinished?()
        }

        // Show the "Done" state briefly, then settle back to idle.
        finishResetTask?.cancel()
        finishResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled, self.countdownPhase == .finished else { return }
            self.countdownPhase = .idle
            self.countdownRemaining = 0
            self.countdownTotal = 0
        }
    }

    // MARK: - Persistence

    private func restorePersistedCountdown() {
        if storedEndDateEpoch > 0 {
            let end = Date(timeIntervalSince1970: storedEndDateEpoch)
            let remaining = end.timeIntervalSinceNow
            if remaining > 0.5 {
                countdownEndDate = end
                countdownTotal = storedRunningTotal > 0 ? storedRunningTotal : remaining
                countdownRemaining = remaining
                countdownPhase = .running
                scheduleCompletionTimer(at: end)
                updateTickTimer()
            } else {
                // Expired while we were gone; the scheduled system notification
                // (if authorized) already announced it.
                clearPersistedCountdown()
            }
        } else if storedPausedRemaining > 0 {
            countdownRemaining = storedPausedRemaining
            countdownTotal = max(storedRunningTotal, storedPausedRemaining)
            countdownPhase = .paused
        }
    }

    private func clearPersistedCountdown() {
        storedEndDateEpoch = 0
        storedRunningTotal = 0
        storedPausedRemaining = 0
    }

    private func restorePersistedPomodoro() {
        guard let phase = PomodoroPhase(rawValue: storedPomodoroPhase), phase != .idle else { return }
        pomodoroPhase = phase
        pomodoroCompletedFocus = storedPomodoroCompletedFocus
        pomodoroTotal = storedPomodoroTotal

        if storedPomodoroEndEpoch > 0 {
            let end = Date(timeIntervalSince1970: storedPomodoroEndEpoch)
            let remaining = end.timeIntervalSinceNow
            if remaining > 0.5 {
                pomodoroEndDate = end
                pomodoroRemaining = remaining
                pomodoroPaused = false
                schedulePomodoroCompletionTimer(at: end)
                updateTickTimer()
            } else {
                // Phase expired while we were away — advance silently and wait.
                advancePomodoro(announce: false)
                if !pomodoroPaused { pausePomodoro() }
            }
        } else if storedPomodoroPausedRemaining > 0 {
            pomodoroRemaining = storedPomodoroPausedRemaining
            pomodoroPaused = true
        } else {
            resetPomodoro()
        }
    }

    private func clearPersistedPomodoro() {
        storedPomodoroPhase = "idle"
        storedPomodoroEndEpoch = 0
        storedPomodoroPausedRemaining = 0
        storedPomodoroTotal = 0
        storedPomodoroCompletedFocus = 0
    }
}

// MARK: - Formatting

/// Shared time formatting for the Timers module.
enum TimersFormatting {
    /// Countdown display: `mm:ss`, or `h:mm:ss` above an hour. Rounds up so a
    /// freshly started 5-minute timer reads 05:00, not 04:59.
    static func countdown(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Stopwatch display with centiseconds: `mm:ss.cc`, or `h:mm:ss.cc`.
    static func stopwatch(_ interval: TimeInterval) -> String {
        let centiTotal = max(0, Int((interval * 100).rounded(.down)))
        let centi = centiTotal % 100
        let total = centiTotal / 100
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d.%02d", hours, minutes, seconds, centi)
        }
        return String(format: "%02d:%02d.%02d", minutes, seconds, centi)
    }

    /// Human phrasing for notifications: "5 min", "1 hr 30 min", "45 sec".
    static func spoken(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hr") }
        if minutes > 0 { parts.append("\(minutes) min") }
        if seconds > 0 && hours == 0 { parts.append("\(seconds) sec") }
        return parts.isEmpty ? "0 sec" : parts.joined(separator: " ")
    }
}
