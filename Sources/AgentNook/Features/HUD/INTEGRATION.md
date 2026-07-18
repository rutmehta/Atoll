# Features/HUD — Integration Guide

System HUD replacement: media-key interception (volume / brightness / mute), CoreAudio
volume tracking, private DisplayServices brightness, and an inline closed-notch HUD.

## Public types

| Type | Kind | Purpose |
|---|---|---|
| `HUDVolumeManager.shared` | `@MainActor ObservableObject` | Default-output-device volume + mute (read/write/listeners). Publishes `volume`, `isMuted`, `lastChangedAt`, `lastChangeSource`, `hasOutputDevice`. |
| `HUDBrightnessManager.shared` | `@MainActor ObservableObject` | Main-display brightness via DisplayServices (dlopen). Publishes `brightness`, `isAvailable`, `lastChangedAt`. |
| `MediaKeyInterceptor.shared` | `@MainActor ObservableObject` | CGEventTap on NSSystemDefined media keys. Publishes `axStatus`, `isTapActive`, `tapCreationFailed`. |
| `SneakPeekCoordinator.shared` | `@MainActor ObservableObject` | HUD display state: `visible`, `type` (`SneakPeekType.volume/.brightness/.mute`), `value` (0...1), `lastEventSource` (`HUDEventSource.internalControl/.external`), `isInteracting`. 1.5 s auto-hide. |
| `HUDWingView(notchWidth:)` | SwiftUI view | Full-width inline HUD for the closed notch: icon left wing, black bridge over the physical notch, draggable progress capsule right wing. |
| `HUDWingLeftView` / `HUDWingRightView` | SwiftUI views | The two wings individually, if the integrator composes wings itself. |
| `HUDSettingsView` | SwiftUI view | Settings pane. |

## Startup calls (AppDelegate, at launch)

```swift
HUDVolumeManager.shared.start()      // CoreAudio device + listeners
HUDBrightnessManager.shared.start()  // dlopen DisplayServices, initial read
MediaKeyInterceptor.shared.start()   // syncs event tap with the "replaceSystemHUD" setting
```

Order does not matter. `SneakPeekCoordinator` needs no start call.

## Closed-notch placement

The HUD **takes precedence over all other wings** while visible. In `ClosedNotchView`:

```swift
@ObservedObject var peek = SneakPeekCoordinator.shared
...
if peek.visible {
    HUDWingView(notchWidth: vm.geometry.notchSize.width)
} else {
    // normal wings (media artwork, timer, battery, agent dots...)
}
```

While `peek.visible`, give the closed notch wings of ~100–120 pt per side
(e.g. `vm.wingWidth = 110`) so the icon and slider have room; restore the previous
wing width when it hides. Height is the normal closed-notch height — the view fills
whatever frame it is given. Keep the notch from auto-opening on hover-drag of the
capsule if desired (`peek.isInteracting` is published for that purpose).

## Settings

Add `HUDSettingsView` as a tab/section ("HUD", suggested symbol `rectangle.tophalf.inset.filled`).

- Master toggle binds to the existing Core `SettingsStore.shared.replaceSystemHUD`
  (`@AppStorage("replaceSystemHUD")`). Turning it ON prompts for Accessibility; the
  interceptor polls every 3 s until granted, then installs the tap. Turning it OFF
  tears the tap down completely — media keys pass through and the system HUD returns.
- `@AppStorage("hud.showOnExternalChange")` (default true): show the notch HUD when
  volume/mute changes externally (menu-bar slider, AirPods, other apps). Independent
  of the master toggle.

## Permissions / Info.plist

- **Accessibility (TCC)** — required for the CGEventTap. No Info.plist key; prompted
  via `AXIsProcessTrustedWithOptions`. The app must run from a real `.app` bundle
  (not a bare SPM binary) for the grant to stick across launches, and must be
  re-granted if the bundle is re-signed ad hoc.
- No sandbox: dlopen of `/System/Library/PrivateFrameworks/DisplayServices.framework`
  and the HID event tap require an unsandboxed app (already the project's model).
- No other Info.plist keys needed by this module.

## Behavior notes

- Media keys handled: NX codes soundUp=0, soundDown=1, brightnessUp=2, brightnessDown=3,
  mute=7. Play/pause/next/etc. are never touched. Steps are 1/16; Option+Shift = 1/64.
- Events are swallowed ONLY when `replaceSystemHUD` is on AND Accessibility is granted;
  otherwise everything passes through (`passUnretained`). Tap re-enables itself on
  `.tapDisabledByTimeout` / `.tapDisabledByUserInput`.
- If DisplayServices symbols are missing, brightness keys pass through to the system
  (never swallowed into a no-op) and the settings pane shows a notice.
- External volume/mute changes are detected via CoreAudio listener blocks and show
  the HUD with `lastEventSource == .external`. External *brightness* changes have no
  notification API and are not detected (value refreshes on next key press).
- Volume feedback tick (`volume.aiff`) plays when the user's "Play feedback when
  volume is changed" system setting is on.
