# Features/Media — Integration

## Views

| View | Placement |
|---|---|
| `MediaPlayerCard` | Open notch, **Home tab** (pairs with the calendar peek). Flexible size; looks best ≥ 380 × 190 pt. Calls `MusicManager.shared.refreshSystemVolume()` on appear by itself. |
| `MediaClosedWingLeft` | Closed-notch **left wing** (artwork thumbnail, 19 pt, rounded 4). Renders `EmptyView` when idle/disabled — gate `vm.wingWidth` on `MusicManager.shared.playback != nil && SettingsStore.shared.mediaLiveActivity`. |
| `MediaClosedWingRight` | Closed-notch **right wing** (4-bar visualizer, tinted with artwork color, animates only while playing). Also renders nothing when idle. |
| `MediaQuickPeekView` | Overlay next to / below the closed notch while `MusicManager.shared.showQuickPeek == true` (published; auto-clears after ~2.8 s on song change). Suggested transition: `.move(edge: .top).combined(with: .opacity)`. |
| `MediaSettingsView` | Settings window tab/section ("Media"). |

Reusable: `MediaAudioVisualizer(isPlaying:tint:barCount:maxBarHeight:barWidth:spacing:)`,
`MediaMarqueeText`, `MediaSeekBar`.

## Startup

```swift
// AppDelegate.applicationDidFinishLaunching
MusicManager.shared.start()   // idempotent; respects the "media.enabled" setting
```

`MusicManager.shared` (`@MainActor ObservableObject`) publishes: `playback: MediaPlaybackState?`,
`artworkTint: Color`, `sourceAppIcon: NSImage?`, `showQuickPeek`, `quickPeekPlayback`,
`usingScriptFallback`, `automationPermissionDenied`, `systemVolume`.
Controls: `togglePlayPause() / nextTrack() / previousTrack() / seek(to:) / toggleShuffle() /
cycleRepeatMode() / setSystemVolume(_:)`.

## Settings keys (module-owned)

`media.enabled` (Bool, default true), `media.restrictTo` ("any" | "appleMusic" | "spotify"),
`media.showVisualizer` (Bool, default true).

## Info.plist / permissions

- **`NSAppleEventsUsageDescription`** — required for the Spotify/Apple Music AppleScript
  fallback ("Atoll controls Spotify and Apple Music to show now-playing info.").
  macOS shows a per-app Automation consent prompt on first fallback use; denial is handled
  gracefully (`automationPermissionDenied` + a "grant access" button in card/settings).
- No other permissions. System volume is set via in-process `set volume output volume`
  (StandardAdditions, no TCC).

## build-app.sh MUST bundle the MediaRemote adapter

The `MediaRemoteAdapter` SPM product is a **dynamic** library. For the notch's
system-wide now-playing stream to work from `dist/Atoll.app`:

1. **Dylib** → `Contents/Frameworks/`:
   ```bash
   mkdir -p "$APP/Contents/Frameworks"
   cp ".build/$CONFIG/libMediaRemoteAdapter.dylib" "$APP/Contents/Frameworks/"
   install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Atoll"
   # optional hygiene for distribution: delete the absolute .build rpath
   codesign --force --sign - "$APP/Contents/Frameworks/libMediaRemoteAdapter.dylib"
   ```
   (The executable links `@rpath/libMediaRemoteAdapter.dylib` and only carries
   `@loader_path` + absolute `.build` rpaths by default — without the added rpath the
   app won't launch on other machines.)
2. **Resource bundle** → `Contents/Resources/`: the existing `*.bundle` copy loop already
   covers `MediaRemoteAdapter_MediaRemoteAdapter.bundle` (contains `run.pl`). Keep it.
3. Codesign the app **after** the dylib.

**No `.framework` wrapper is needed.** Important background: the package's own
`MediaController.startListening()` resolves its dylib via
`Bundle(for:).executablePath`, which is nil in bare-SPM layouts (it would
`assertionFailure` in debug and silently break in release). This module therefore drives
the adapter itself (`MediaAdapterTransport`): it resolves the loaded dylib via
`class_getImageName(MediaController.self)` and searches `run.pl` in
`Contents/Resources/<bundle>`, next to the dylib (`.build/<config>/`, so `swift run`
dev builds work), and `Frameworks/../Resources`. It spawns
`/usr/bin/perl run.pl <dylib> loop` (the `com.apple.perl5` MediaRemote loophole) and
speaks the package's stdin command protocol; `TrackInfo` decoding is reused from the
package.

## Behavior notes

- **Fallback**: if the adapter delivers nothing for 5 s (e.g. resources missing or a
  future macOS breaking the loophole) AND Spotify or Music is running, AppleScript
  polling (3 s + DistributedNotificationCenter playback notifications) takes over
  automatically; it hands back the moment the adapter delivers. When neither player runs,
  it re-probes every 10 s.
- Playback position is extrapolated client-side from (elapsed, timestamp, rate) — no
  polling while the seek bar renders (`TimelineView`).
- Wing/QuickPeek views observe `MusicManager.shared` directly; no wiring beyond placement.
- `SettingsStore.mediaLiveActivity` (Core) is the integrator-level live-activity gate;
  this module's `media.enabled` disables the whole widget including the open-notch card.
