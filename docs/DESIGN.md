# AgentNook — Design & Module Contract

Open-source NotchNook replica + Claude Code / Codex session monitoring (Notchi-style).
SPM executable target, macOS 14+, Swift 5 language mode, unsandboxed, bundled via
`scripts/build-app.sh` into `dist/AgentNook.app`.

Research inputs live in `docs/research/` — **read the file(s) relevant to your module
before implementing**:
- `research-notchnook.md` — full NotchNook feature parity list
- `research-notchi.md` — agent-session monitoring architecture (hooks, socket, approvals)
- `research-boringnotch.md` — proven implementation techniques (window, media, shelf, HUD)
- `research-apis.md` — code-level macOS API recipes
- `research-critic.md` — corrections (Codex has ~10 hook events now; OAuth usage endpoint needs User-Agent)

## Core (already built — do not modify)

- `Core/NotchGeometry.swift` — notch measurement per screen (`NotchGeometry.forScreen`)
- `Core/NotchPanel.swift` — `NotchController` owns the always-open-size NSPanel
- `Core/NotchViewModel.swift` — `NotchViewModel` (`state: NotchState` closed/open, `tab: NotchTab`,
  `open(tab:)`, `close()`, `toggle()`, `hoverChanged(_:)`, `isDropTargeted`, `geometry`, `openSize`, `closedSize`)
- `Core/SettingsStore.swift` — `SettingsStore.shared`, `@AppStorage`-backed
- `UI/NotchShape.swift` — animatable notch silhouette
- `UI/NotchRootView.swift`, `UI/OpenNotchView.swift`, `UI/SettingsRootView.swift` — integration
  points, wired by the integrator after modules land

## Module rules (for implementation agents)

1. Create files **only** under your assigned directory `Sources/AgentNook/Features/<Module>/`.
2. Do **not** modify `Package.swift`, `Core/*`, `UI/*`, `App/*`, `scripts/*`, or another
   module's directory. The integrator wires everything afterward.
3. Expose: one or more `ObservableObject` managers (singleton `static let shared` where it
   makes sense) plus SwiftUI views. Reference only Core types and Apple frameworks — never
   another feature module.
4. Feature-specific settings: use `@AppStorage` keys (prefix them, e.g. `"shelf.autoRemove"`)
   inside your module, plus a `<Module>SettingsView` the integrator adds to the settings window.
5. Write `Sources/AgentNook/Features/<Module>/INTEGRATION.md` describing exactly: view names +
   intended placement (which tab / closed-notch wing / HUD overlay), manager start-up calls the
   app must make at launch, settings view name, and required Info.plist keys or permissions.
6. Your code must compile: run `swift build --package-path /Users/rutmehta/Developer/AgentNook`
   and fix errors before finishing. Do not run git commands. Language mode is Swift 5 —
   avoid strict-concurrency-only idioms; annotate UI-facing classes `@MainActor` as needed.
7. Closed-notch live activities: provide a compact SwiftUI view designed for a wing next to
   the physical notch (height = notch height, ~28-36 pt), e.g. `MediaClosedWingLeft/Right`.
   The integrator composes them into `ClosedNotchView`.

## Modules & owners

| Module dir | Contents |
|---|---|
| `Features/Media` | MediaRemoteAdapter (SPM dep `MediaRemoteAdapter`, already in Package.swift) now-playing stream + controls; AppleScript Spotify/Music fallback; `MusicManager`; open-notch player card (artwork, title/artist, seek bar, shuffle/repeat, source label); animated audio-bars visualizer (pauses when paused); closed wings (artwork left, visualizer right); artwork average-color tinting |
| `Features/Shelf` | Tray: `.onDrop` ingestion (fileURL/url/text/data), security-scoped bookmarks, persistence in Application Support, stacking UI, multi-select, Quick Look, thumbnails (QuickLookThumbnailing), drag-out via NSDraggingSource NSViewRepresentable, AirDrop drop zone (`NSSharingService(.sendViaAirDrop)`), share picker, paste-from-clipboard, remove/reveal context menu, global `DragDetector` (drag near notch → callback to auto-open shelf) |
| `Features/CalendarWidget` | EventKit full access; day strip with prev/next day paging; per-calendar picker; all-day filter; event rows (color dot, time, title); click → open Calendar.app; "next event" compact wing view |
| `Features/Mirror` | AVCaptureSession webcam preview, device picker (built-in + external + Continuity), mirroring toggle, aspect-fill layer in NSViewRepresentable, start/stop with tab visibility |
| `Features/Timers` | Timer widget (duration wheel/stepper, countdown, pause/resume/cancel, notification + sound on finish), stopwatch, closed-notch countdown wing |
| `Features/Notes` | Quick notes: multiline editor, list of notes, autosave to Application Support (JSON), Esc handling note, delete/duplicate |
| `Features/Todos` | To-dos: add, complete (strikethrough + auto-archive), favorites (pin to top), persisted JSON; compact count badge view |
| `Features/ShortcutsRunner` | macOS Shortcuts widget: list via `shortcuts list` CLI, run via `shortcuts run <name>` (Process), favorites, running indicator |
| `Features/HUD` | Media-key CGEventTap (swallow volume/brightness/mute when enabled + Accessibility granted), CoreAudio `VolumeManager` (read/write/listeners), `BrightnessManager` (DisplayServices via dlopen), `SneakPeekCoordinator.shared` (type/value/visible, 1.5 s auto-hide), inline closed-notch HUD view (icon left, bridge over notch, draggable progress right), AX permission prompt flow |
| `Features/SystemEvents` | Battery via IOPSNotification (charging/unplugged/full/low + low-power mode) → live-activity events + battery wing view; Bluetooth connect/disconnect via IOBluetooth notifications |
| `Features/Agents` | THE flagship. Socket server (`/tmp/agentnook.sock`), hook installer (opt-in UI button; idempotent upsert of `~/.claude/settings.json` hooks + `~/.codex/hooks.json`; uninstaller prunes only ours), hook shell script (bash+python3, event→status map, PID ancestry capture, blocking PermissionRequest reply ≤290 s), session store + state machine (idle/working/waitingForInput/permissionRequest/compacting/ended), transcript tailing (Claude JSONL + Codex rollout, incremental offsets), Codex liveness `kill(pid,0)`, jump-to-terminal (proc ancestry → NSRunningApplication.activate, terminal allowlist), notifications (UNUserNotificationCenter, mute when terminal frontmost) |
| `Features/AgentsUI` | Session list rows (state dot/spinner, project #N, permission-mode badge, last message), live activity feed (tool events running/success/error + assistant messages), permission approval card (tool + input summary, Allow / Allow&remember / Deny buttons, number-key shortcuts, AskUserQuestion options + free text), usage quota manager (Claude keychain OAuth token via `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` → `GET api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20` AND `User-Agent: claude-code/2.0`; Codex `~/.codex/auth.json` JWT → `chatgpt.com/backend-api/wham/usage`), usage bars (green<50/amber<80/red≥80, "Resets in Xh Ym"), 30-day cost dashboard (incremental JSONL scan with per-file offset cache, models.dev pricing + bundled fallback), closed-notch wing (one dot per live session, color = state, pulse on needs-attention) |

`Features/Agents` ↔ `Features/AgentsUI` may share types: AgentsUI may `import` nothing extra but
may reference `Features/Agents` public types (same target — just don't edit its files).
AgentsUI should consume `AgentSessionStore.shared` published state.

## Integration (after modules land — integrator only)

- `OpenNotchView` tabs: Home = media player + calendar peek; Shelf; Agents; Tools = grid of
  mirror/timer/notes/todos/shortcuts; Settings gear → settings window.
- `ClosedNotchView` wings: media artwork/visualizer, HUD overlay (takes precedence),
  timer countdown, battery events (3 s auto-hide), agent session dots.
- `AppDelegate`: start managers, register drag detector → `vm.open(tab: .shelf)`,
  global keyboard shortcut (toggle), screen-change rebuilds.
- Settings window: add each module's settings view as a tab/section.
- `scripts/build-app.sh`: copy `libMediaRemoteAdapter.dylib` + resource bundles into the
  app, fix rpath (`install_name_tool -add_rpath @executable_path/../Frameworks`).

## Explicit non-goals for v0.1

Sparkle updates, localization, Metal visualizer, lock-screen SkyLight window, XPC helper
(private-API calls stay in-process), Mac App Store distribution, keyboard backlight HUD.
