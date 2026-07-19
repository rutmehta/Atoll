# Features/SystemEvents — Integration

Battery + Bluetooth live activities for the closed notch.

## Managers (start at app launch)

```swift
// In AppDelegate / app startup (both are @MainActor):
BatteryMonitor.shared.start()      // no permissions needed
BluetoothMonitor.shared.start()    // triggers macOS Bluetooth privacy prompt on first use
```

Both expose `stop()` but as singletons they normally run for the app's lifetime.

## Published state / events

- `BatteryMonitor.shared`
  - Continuous: `percentage: Int`, `isCharging`, `isPluggedIn`, `isCharged`,
    `isLowPowerMode`, `timeRemainingMinutes: Int?` (to-full while charging,
    to-empty on battery, nil while estimating), `hasBattery: Bool` (false on desktops
    — hide all battery UI).
  - Events: `events: PassthroughSubject<BatteryEvent, Never>` and mirrored
    `@Published lastEvent` / `lastEventDate`. Cases: `.pluggedIn(percentage:)`,
    `.unplugged(percentage:)`, `.chargedFull`, `.lowBattery(percentage:)` (fires once
    at ≤20% and once at ≤10% per discharge cycle), `.lowPowerModeChanged(enabled:)`.
    Deliveries are spaced ≥1 s apart. `eventStatusText` gives the display label
    ("Charging", "Fully Charged", "Low Battery", "Low Power: On", …).
- `BluetoothMonitor.shared`
  - `events: PassthroughSubject<BluetoothEvent, Never>` + `@Published lastEvent` /
    `lastEventDate`. `BluetoothEvent { deviceName, connected, deviceKind, date }`.
  - `connectedDeviceNames: [String]`, `permissionDenied: Bool`.

Event emission already respects the user toggles (`batteryLiveActivity`,
`systemEvents.lowBatteryAlerts`, `systemEvents.bluetoothLiveActivity`) — when a
toggle is off, no events fire, so the integrator does not need to re-check settings
before showing a wing (checking `SettingsStore.shared.batteryLiveActivity` again is
harmless but redundant).

## Views + placement

| View | Placement |
|---|---|
| `BatteryWingView(variant: .indicator)` | Optional persistent right wing of the closed notch (battery glyph; % text only when the "Always show percentage" setting is on). Renders empty on Macs without a battery. |
| `BatteryWingView(variant: .event)` | Closed-notch live activity: show for ~3 s when `BatteryMonitor.shared.events` fires (status text + % + glyph, ~28 pt tall). |
| `BluetoothEventWingView()` (or `BluetoothEventWingView(event: e)`) | Closed-notch live activity: show for ~3 s when `BluetoothMonitor.shared.events` fires (device icon + name + Connected/Disconnected, ~28 pt tall, max width 170). |

Suggested wiring in `ClosedNotchView` (integrator-owned):

```swift
.onReceive(BatteryMonitor.shared.events) { _ in showBatteryWing(for: 3) }
.onReceive(BluetoothMonitor.shared.events) { _ in showBluetoothWing(for: 3) }
```

HUD overlay should take precedence over these wings per the design doc.

## Settings

`SystemEventsSettingsView` — add to the settings window (suggested tab: "System",
icon `battery.100.bolt` or `bolt.badge.clock`). Toggles: battery live activity
(shared key `batteryLiveActivity`, same as `SettingsStore.shared.batteryLiveActivity`),
always show percentage (`systemEvents.showBatteryPercentAlways`), low battery alerts
(`systemEvents.lowBatteryAlerts`), bluetooth live activity
(`systemEvents.bluetoothLiveActivity`). Includes a permission warning + "Open Privacy
Settings…" button when Bluetooth access is denied.

## Permissions / Info.plist

- Battery: none.
- Bluetooth: add to Info.plist (required on macOS 11+ for IOBluetooth):

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Atoll shows a notch notification when Bluetooth devices connect or disconnect.</string>
```

macOS shows the privacy prompt automatically on first IOBluetooth use. If denied,
`BluetoothMonitor.shared.permissionDenied` becomes true, monitoring is skipped
(no crash), and the settings view offers the System Settings deep link.
`BluetoothMonitor.shared.retryAfterPermissionChange()` re-checks and restarts.

## Implementation notes

- Battery: `IOPSNotificationCreateRunLoopSource` on the main run loop +
  `IOPSCopyPowerSourcesInfo/List/GetPowerSourceDescription` snapshot diffing;
  low-power mode via `NSProcessInfoPowerStateDidChange`.
- Bluetooth: `IOBluetoothDevice.register(forConnectNotifications:selector:)` +
  per-device disconnect notifications; automatic fallback to polling
  `IOBluetoothDevice.pairedDevices()` every 5 s if registration fails. Devices
  already connected at launch are baselined without emitting events.
