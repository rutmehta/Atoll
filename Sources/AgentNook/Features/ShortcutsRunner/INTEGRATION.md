# ShortcutsRunner — Integration Notes

macOS Shortcuts widget: lists shortcuts via the `/usr/bin/shortcuts` CLI, runs them
with per-shortcut spinner + green/red result flash, favorites float to top, search
filter, per-shortcut hide via settings.

## Views

| View | Placement |
|---|---|
| `ShortcutsWidgetView` | Open notch, **Tools tab** grid cell. Dark-theme styled (white text on translucent chips); flexible size, works well from ~260 × 160 pt up. Handles its own loading / error / empty states, including "Shortcuts CLI missing". |
| `ShortcutsSettingsView` | Settings window tab/section titled **"Shortcuts"** (suggested icon: `app.connected.to.app.below.fill`). Standard grouped `Form`, follows system appearance. |

No closed-notch wing — this module has no live activity.

## Manager

- `ShortcutsManager.shared` (`@MainActor ObservableObject`, singleton).
- **No startup call required.** The widget and settings views call
  `manager.refreshOnAppear()` themselves (throttled to one `shortcuts list` per 20 s).
  Optionally call `ShortcutsManager.shared.refresh()` in `AppDelegate` at launch to
  pre-warm the list so the Tools tab opens populated.
- Key published state: `allShortcuts`, `widgetShortcuts` (hidden filtered, search
  applied, favorites first), `loadState`, `runningNames`, `recentOutcomes`,
  `searchText`.

## Persistence

`@AppStorage` JSON string arrays (UserDefaults, no files):

- `shortcuts.favorites` — favorited shortcut names
- `shortcuts.hidden` — names hidden from the widget

## Permissions / Info.plist

- **None required.** Uses `Process` on `/usr/bin/shortcuts` (app is unsandboxed).
- No Apple Events, so no `NSAppleEventsUsageDescription`.
- A running shortcut may itself present Shortcuts-app permission prompts or UI —
  that is macOS behavior, outside the app.
- If the CLI is missing (it ships with macOS 12+; app targets 14+ so effectively
  always present), the widget shows an explanatory empty state instead of crashing.
