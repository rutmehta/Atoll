import AppKit
import Combine
import EventKit
import SwiftUI

/// Calendars grouped under their account/source (iCloud, Google, "On My Mac", …)
/// for the settings picker.
struct CalendarSourceGroup: Identifiable {
    let id: String
    let title: String
    let calendars: [EKCalendar]
}

/// EventKit-backed calendar state for the notch widget.
///
/// - Requests full access only when the user presses the enable button
///   (`requestAccess()`), never at launch.
/// - Refreshes on `.EKEventStoreChanged`, on a 5-minute timer, and recomputes
///   the "next event" wing every minute so it clears shortly after events end.
/// - Persists the enabled-calendar set as JSON in `@AppStorage`
///   (`"calendar.enabledCalendarIDs"`); an empty value means "all calendars".
@MainActor
final class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    // MARK: - Published state

    @Published private(set) var authorizationStatus: EKAuthorizationStatus
    @Published private(set) var displayedDate: Date = Date()
    @Published private(set) var displayedEvents: [EKEvent] = []
    /// Next non-all-day event today that has not ended yet (ongoing counts).
    @Published private(set) var nextEvent: EKEvent? = nil
    @Published private(set) var calendarGroups: [CalendarSourceGroup] = []
    @Published private(set) var isRequestingAccess = false

    var hasFullAccess: Bool { authorizationStatus == .fullAccess }
    var isDisplayingToday: Bool { Calendar.current.isDateInToday(displayedDate) }

    // MARK: - Settings

    /// JSON array of enabled calendar identifiers. Empty string = never
    /// customized = every calendar enabled (so new calendars show up by default).
    @AppStorage("calendar.enabledCalendarIDs") private var enabledCalendarIDsJSON = ""

    @AppStorage("calendar.hideAllDay") var hideAllDayEvents = false {
        willSet { objectWillChange.send() }
        didSet { refresh() }
    }

    @AppStorage("calendar.hideMultiDay") var hideMultiDayEvents = false {
        willSet { objectWillChange.send() }
        didSet { refresh() }
    }

    // MARK: - Private

    private var store = EKEventStore()
    private var storeObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var wingTimer: Timer?
    /// While true, `refresh()` snaps `displayedDate` forward when midnight passes.
    private var followsToday = true

    private init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        refreshTimer?.invalidate()
        wingTimer?.invalidate()
    }

    // MARK: - Lifecycle

    /// Call once at app launch. Never triggers a permission prompt.
    func start() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        guard hasFullAccess else { return }
        beginObserving()
        refresh()
    }

    /// Button-triggered system permission prompt (only valid while `.notDetermined`).
    func requestAccess() {
        guard authorizationStatus == .notDetermined, !isRequestingAccess else { return }
        isRequestingAccess = true
        Task { [weak self] in
            guard let self else { return }
            let granted = (try? await self.store.requestFullAccessToEvents()) ?? false
            self.isRequestingAccess = false
            self.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            if granted {
                // Fresh store after a grant avoids stale pre-authorization caches.
                self.store = EKEventStore()
                self.beginObserving()
            }
            self.refresh()
        }
    }

    /// Deep link into System Settings > Privacy & Security > Calendars.
    func openCalendarPrivacySettings() {
        let link = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    private func beginObserving() {
        guard storeObserver == nil else { return }
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        let refresh = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(refresh, forMode: .common)
        refreshTimer = refresh

        // Keep the "next event" wing fresh (clears soon after an event ends).
        let wing = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hasFullAccess else { return }
                self.nextEvent = self.computeNextEvent()
            }
        }
        RunLoop.main.add(wing, forMode: .common)
        wingTimer = wing
    }

    // MARK: - Refresh & queries

    func refresh() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        guard hasFullAccess else {
            displayedEvents = []
            nextEvent = nil
            calendarGroups = []
            return
        }
        beginObserving()
        if followsToday, !Calendar.current.isDateInToday(displayedDate) {
            displayedDate = Date()
        }
        rebuildCalendarGroups()
        displayedEvents = events(for: displayedDate)
        nextEvent = computeNextEvent()
    }

    /// Filtered, sorted events for the given calendar day (all-day events first).
    func events(for date: Date) -> [EKEvent] {
        guard hasFullAccess else { return [] }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let calendars = allCalendars.filter { isCalendarEnabled($0) }
        guard !calendars.isEmpty else { return [] }

        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: calendars)
        var events = store.events(matching: predicate)
        if hideAllDayEvents { events.removeAll { $0.isAllDay } }
        if hideMultiDayEvents { events.removeAll { Self.isMultiDay($0) } }
        return events.sorted { a, b in
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            return a.compareStartDate(with: b) == .orderedAscending
        }
    }

    /// True when the event spans more than one calendar day
    /// (an end exactly at midnight does not count as spilling into the next day).
    static func isMultiDay(_ event: EKEvent) -> Bool {
        guard let start = event.startDate, let end = event.endDate, end > start else { return false }
        return !Calendar.current.isDate(start, inSameDayAs: end.addingTimeInterval(-1))
    }

    private func computeNextEvent() -> EKEvent? {
        let now = Date()
        return events(for: now).first { event in
            guard !event.isAllDay, let end = event.endDate else { return false }
            return end > now
        }
    }

    // MARK: - Day paging

    func goToPreviousDay() { shiftDay(by: -1) }
    func goToNextDay() { shiftDay(by: 1) }

    func goToToday() {
        followsToday = true
        displayedDate = Date()
        displayedEvents = events(for: displayedDate)
    }

    private func shiftDay(by delta: Int) {
        guard let shifted = Calendar.current.date(byAdding: .day, value: delta, to: displayedDate) else { return }
        followsToday = Calendar.current.isDateInToday(shifted)
        displayedDate = shifted
        displayedEvents = events(for: shifted)
    }

    // MARK: - Calendar enable/disable

    var allCalendars: [EKCalendar] {
        guard hasFullAccess else { return [] }
        return store.calendars(for: .event)
    }

    func isCalendarEnabled(_ calendar: EKCalendar) -> Bool {
        guard let enabled = enabledCalendarIDs else { return true }
        return enabled.contains(calendar.calendarIdentifier)
    }

    func setCalendar(_ calendar: EKCalendar, enabled: Bool) {
        var ids = enabledCalendarIDs ?? Set(allCalendars.map(\.calendarIdentifier))
        if enabled {
            ids.insert(calendar.calendarIdentifier)
        } else {
            ids.remove(calendar.calendarIdentifier)
        }
        enabledCalendarIDs = ids
    }

    func enableAllCalendars() { enabledCalendarIDs = nil }
    func disableAllCalendars() { enabledCalendarIDs = [] }

    /// `nil` means "all calendars enabled" (the default before any customization).
    private var enabledCalendarIDs: Set<String>? {
        get {
            guard !enabledCalendarIDsJSON.isEmpty,
                  let data = enabledCalendarIDsJSON.data(using: .utf8),
                  let ids = try? JSONDecoder().decode([String].self, from: data)
            else { return nil }
            return Set(ids)
        }
        set {
            objectWillChange.send()
            if let newValue,
               let data = try? JSONEncoder().encode(newValue.sorted()),
               let json = String(data: data, encoding: .utf8) {
                enabledCalendarIDsJSON = json
            } else {
                enabledCalendarIDsJSON = ""
            }
            refresh()
        }
    }

    private func rebuildCalendarGroups() {
        let grouped = Dictionary(grouping: allCalendars) { calendar in
            calendar.source?.sourceIdentifier ?? "local"
        }
        calendarGroups = grouped
            .map { key, calendars -> CalendarSourceGroup in
                let title = calendars.first?.source?.title ?? "Other"
                let sorted = calendars.sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return CalendarSourceGroup(id: key, title: title, calendars: sorted)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Open in Calendar.app

    /// Tries to deep-link Calendar.app to the specific event occurrence
    /// (`ical://ekevent/...`), falling back to just activating Calendar.app.
    func openInCalendarApp(_ event: EKEvent) {
        var opened = false
        if let start = event.startDate,
           let id = event.calendarItemIdentifier
               .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let stamp = formatter.string(from: start)
            if let url = URL(string: "ical://ekevent/\(stamp)/\(id)?method=showEvent&options=more") {
                opened = NSWorkspace.shared.open(url)
            }
        }
        if !opened,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
