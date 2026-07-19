import AppKit
import Combine
import Foundation
import IOKit.ps

// MARK: - BatteryEvent

/// A significant battery state change worth surfacing as a closed-notch live activity.
enum BatteryEvent: Equatable {
    case pluggedIn(percentage: Int)
    case unplugged(percentage: Int)
    case chargedFull
    case lowBattery(percentage: Int)
    case lowPowerModeChanged(enabled: Bool)
}

// MARK: - BatteryMonitor

/// Watches the internal battery via IOKit power-source notifications and publishes
/// both continuous state (`percentage`, `isCharging`, `timeRemainingMinutes`, …) and
/// discrete `BatteryEvent`s (plugged in / unplugged / full / low / low-power mode),
/// spaced at least 1 second apart.
///
/// Call `BatteryMonitor.shared.start()` once at app launch. No permissions required.
@MainActor
final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()

    // MARK: Continuously published state

    /// 0–100. Defaults to 100 on Macs without an internal battery.
    @Published private(set) var percentage: Int = 100
    @Published private(set) var isCharging = false
    @Published private(set) var isPluggedIn = true
    @Published private(set) var isCharged = false
    @Published private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// Minutes to full charge while charging, minutes to empty on battery.
    /// `nil` while macOS is still estimating (or on desktops).
    @Published private(set) var timeRemainingMinutes: Int?
    /// False on desktop Macs — hide battery UI entirely in that case.
    @Published private(set) var hasBattery = false

    // MARK: Events

    /// Most recent significant event; mirrors `events`. The integrator typically
    /// shows `BatteryWingView(variant: .event)` for ~3 s whenever this changes.
    @Published private(set) var lastEvent: BatteryEvent?
    @Published private(set) var lastEventDate: Date?
    /// Typed event stream with a minimum of 1 s between deliveries.
    let events = PassthroughSubject<BatteryEvent, Never>()

    /// Human-readable label for the current `lastEvent` ("Charging", "Fully Charged", …).
    var eventStatusText: String {
        guard let lastEvent else { return "" }
        switch lastEvent {
        case .pluggedIn:
            return isCharging ? "Charging" : "Plugged In"
        case .unplugged:
            return "On Battery"
        case .chargedFull:
            return "Fully Charged"
        case .lowBattery:
            return "Low Battery"
        case .lowPowerModeChanged(let enabled):
            return enabled ? "Low Power: On" : "Low Power: Off"
        }
    }

    // MARK: Internals

    private struct Snapshot: Equatable {
        var hasBattery = false
        var percentage = 100
        var isCharging = false
        var isPluggedIn = true
        var isCharged = false
        var timeToFullMinutes: Int?
        var timeToEmptyMinutes: Int?
    }

    private var started = false
    private var runLoopSource: CFRunLoopSource?
    private var powerStateObserver: NSObjectProtocol?
    private var previousSnapshot: Snapshot?
    /// Low-battery thresholds that already fired for the current discharge cycle.
    private var firedLowThresholds: Set<Int> = []
    private var didAnnounceFull = false

    // 1 s minimum spacing between event deliveries.
    private var pendingEvents: [BatteryEvent] = []
    private var isDraining = false
    private var lastEmitDate = Date.distantPast
    private static let minimumEventSpacing: TimeInterval = 1.0

    private init() {}

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true

        refresh(emitEvents: false)

        // IOKit notifies on any power-source change (plug/unplug, capacity ticks, …).
        // The callback fires on the run loop the source is added to (main).
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                monitor.refresh(emitEvents: true)
            }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }

        powerStateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleLowPowerModeChange()
            }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
        }
        powerStateObserver = nil
        pendingEvents.removeAll()
    }

    // MARK: Refresh + diffing

    private func refresh(emitEvents: Bool) {
        let snapshot = Self.readSnapshot()
        let previous = previousSnapshot
        previousSnapshot = snapshot

        hasBattery = snapshot.hasBattery
        percentage = snapshot.percentage
        isCharging = snapshot.isCharging
        isPluggedIn = snapshot.isPluggedIn
        isCharged = snapshot.isCharged
        timeRemainingMinutes = snapshot.isPluggedIn
            ? snapshot.timeToFullMinutes
            : snapshot.timeToEmptyMinutes

        // Reset one-shot latches whenever their trigger condition clears,
        // regardless of whether events are enabled right now.
        if snapshot.isPluggedIn || snapshot.percentage > 20 {
            firedLowThresholds.removeAll()
        }
        if !snapshot.isPluggedIn || snapshot.percentage < 95 {
            didAnnounceFull = false
        }

        guard emitEvents,
              snapshot.hasBattery,
              let previous,
              previous.hasBattery,
              batteryLiveActivityEnabled
        else { return }

        if snapshot.isPluggedIn != previous.isPluggedIn {
            enqueue(snapshot.isPluggedIn
                ? .pluggedIn(percentage: snapshot.percentage)
                : .unplugged(percentage: snapshot.percentage))
        }

        if snapshot.isPluggedIn,
           snapshot.isCharged || snapshot.percentage >= 100,
           !didAnnounceFull {
            didAnnounceFull = true
            enqueue(.chargedFull)
        }

        if !snapshot.isPluggedIn, lowBatteryAlertsEnabled {
            let newlyCrossed = [20, 10].filter {
                snapshot.percentage <= $0 && !firedLowThresholds.contains($0)
            }
            if !newlyCrossed.isEmpty {
                firedLowThresholds.formUnion(newlyCrossed)
                enqueue(.lowBattery(percentage: snapshot.percentage))
            }
        }
    }

    private func handleLowPowerModeChange() {
        let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard enabled != isLowPowerMode else { return }
        isLowPowerMode = enabled
        guard batteryLiveActivityEnabled else { return }
        enqueue(.lowPowerModeChanged(enabled: enabled))
    }

    // MARK: Settings

    private var batteryLiveActivityEnabled: Bool {
        SettingsStore.shared.batteryLiveActivity
    }

    private var lowBatteryAlertsEnabled: Bool {
        (UserDefaults.standard.object(forKey: "systemEvents.lowBatteryAlerts") as? Bool) ?? true
    }

    // MARK: Event queue (1 s spacing)

    private func enqueue(_ event: BatteryEvent) {
        pendingEvents.append(event)
        drainQueue()
    }

    private func drainQueue() {
        guard !isDraining, !pendingEvents.isEmpty else { return }
        isDraining = true
        let wait = max(0, Self.minimumEventSpacing - Date().timeIntervalSince(lastEmitDate))
        Task { @MainActor [weak self] in
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            guard let self else { return }
            self.isDraining = false
            guard !self.pendingEvents.isEmpty else { return }
            let event = self.pendingEvents.removeFirst()
            self.lastEmitDate = Date()
            self.lastEvent = event
            self.lastEventDate = self.lastEmitDate
            self.events.send(event)
            self.drainQueue()
        }
    }

    // MARK: IOKit snapshot

    private static func readSnapshot() -> Snapshot {
        var snapshot = Snapshot()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return snapshot }

        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }
            // Only the internal battery drives the live activity.
            guard (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }

            snapshot.hasBattery = true

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            if maximum > 0 {
                snapshot.percentage = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
            } else {
                snapshot.percentage = min(100, max(0, current))
            }

            snapshot.isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            snapshot.isPluggedIn = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            snapshot.isCharged = description[kIOPSIsChargedKey] as? Bool
                ?? (snapshot.isPluggedIn && snapshot.percentage >= 100)

            // IOKit reports -1 (kIOPSTimeRemainingUnknown) while still estimating.
            if let toFull = description[kIOPSTimeToFullChargeKey] as? Int, toFull > 0 {
                snapshot.timeToFullMinutes = toFull
            }
            if let toEmpty = description[kIOPSTimeToEmptyKey] as? Int, toEmpty > 0 {
                snapshot.timeToEmptyMinutes = toEmpty
            }
            break
        }
        return snapshot
    }
}
