# Features/Timers — Integration Guide

## Views

| View | Placement |
|---|---|
| `TimersWidgetView` | Open notch, **Tools** tab (grid cell). Self-contained dark card (own rounded background, `minWidth: 220, maxWidth: 340`, ~200 pt tall). Segmented Timer \| Stopwatch. |
| `TimerClosedWing` | Closed-notch live-activity wing (either side). Renders `EmptyView` when no countdown is active, so it can be composed unconditionally; still gate on `settings.timerLiveActivity` to honor the master toggle: `if settings.timerLiveActivity { TimerClosedWing() }`. Stretches to wing height (designed for 28-36 pt). |
| `TimersSettingsView` | Settings window tab/section, e.g. `.tabItem { Label("Timers", systemImage: "timer") }`. Uses grouped `Form` like the existing settings panes. |

## Startup calls (AppDelegate / app launch)

```swift
// 1. Touch the singleton early so a countdown persisted across relaunch resumes
//    (it restores from @AppStorage anchor dates in init).
let timers = TimerManager.shared

// 2. Wire auto-open on completion (manager already gates this behind the
//    "timers.autoOpenOnComplete" setting — just open the notch here).
timers.onCountdownFinished = { [weak vm] in
    vm?.open(tab: .tools)
}
```

No teardown needed; the tick timer only runs while a countdown/stopwatch is active.

## Behavior notes

- Countdown + stopwatch are computed from `Date` anchors (drift-free); published values tick at 0.5 s, the stopwatch display uses a `TimelineView` for smooth centiseconds.
- A running countdown survives relaunch (`timers.endDateEpoch` anchor). A paused one survives too (`timers.pausedRemaining`).
- On completion: plays the chosen `NSSound` in-app, and a **pre-scheduled** `UNTimeIntervalNotificationTrigger` banner fires (silent banner; sound comes from NSSound) — the banner fires even if the app quit before the timer ended.
- Notification authorization is requested lazily on first timer start (and from the settings pane's "Enable Notifications" button). Denied/unavailable states degrade gracefully (timer still works, sound still plays).

## Permissions / Info.plist

- **User notifications**: no usage-description key required, but `UNUserNotificationCenter` needs a real bundle — all notification code is gated on `Bundle.main.bundleIdentifier != nil` so bare `swift run` never crashes. Ship via `scripts/build-app.sh` bundle.
- No other permissions.

## @AppStorage keys (all `timers.`-prefixed)

`timers.completionSound` (String, default "Glass"), `timers.autoOpenOnComplete` (Bool, default true), `timers.configuredDuration`, `timers.endDateEpoch`, `timers.runningTotal`, `timers.pausedRemaining`, `timers.selectedMode`.

## Public types

`TimerManager` (@MainActor singleton `ObservableObject`), `TimerLap`, `TimersFormatting` (time-string helpers), `TimersWidgetView`, `TimerClosedWing`, `TimersSettingsView`.
