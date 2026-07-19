# Features/Mirror — Integration

## Views

| View | Placement |
|---|---|
| `MirrorView` | Open notch, **Tools tab** (grid cell or expanded pane). Works at any size; looks best at ≥ 200×140 pt. Handles its own permission / no-camera fallback states. |
| `MirrorSettingsView` | Settings window tab/section ("Mirror"). |

No closed-notch wing for this module.

## Manager

`MirrorManager.shared` (`@MainActor ObservableObject`). Fully lazy — **no start-up call
is required at app launch**. First access happens when `MirrorView` appears.

Session lifecycle is driven by view visibility: `MirrorView` itself calls
`manager.previewDidAppear()` / `manager.previewDidDisappear()` in
`onAppear`/`onDisappear`, so the camera only runs while the mirror is on screen.
The integrator does not need to call these.

**Recommended safety net** (guarantees the camera light turns off when the notch
collapses even if SwiftUI keeps the tab view tree alive). In the AppDelegate /
wherever `NotchViewModel.onStateChange` is wired:

```swift
vm.onStateChange = { state in
    if state == .closed {
        MirrorManager.shared.notchDidClose()
    }
    // ... other modules
}
```

## Public API summary

- `MirrorManager.shared.session: AVCaptureSession`
- `authStatus: MirrorAuthStatus` (`.notDetermined/.denied/.restricted/.authorized`)
- `devices: [AVCaptureDevice]`, `activeDevice`, `isSessionRunning`
- `selectedCameraID: String` (persisted, `""` = automatic), `isMirrored: Bool` (persisted, default `true`)
- `requestAccess()`, `startSession()`, `stopSession()`, `notchDidClose()`
- `MirrorManager.openCameraPrivacySettings()`

## Settings keys (`@AppStorage`)

- `mirror.selectedCameraID` — preferred camera uniqueID (`""` = automatic)
- `mirror.isMirrored` — horizontal flip, default `true`

## Info.plist / permissions

Required (app will crash on camera access without it):

```xml
<key>NSCameraUsageDescription</key>
<string>Atoll shows a live camera preview in the notch mirror.</string>
```

Recommended (opts in to Continuity Camera discovery; without it the
`.continuityCamera` device type logs a runtime warning and iPhone cameras may not
be listed):

```xml
<key>NSCameraUseContinuityCameraDeviceType</key>
<true/>
```

App is unsandboxed, so no camera entitlement is needed. (If sandboxing is ever
enabled: `com.apple.security.device.camera`.)
