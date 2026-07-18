# Features/Notes — Integration

## Views

- `NotesWidgetView` — the full notes UI (note list left, editor right).
  Intended placement: the **Tools** tab of `OpenNotchView` (or its own pane in
  the tools grid). Designed for the open-notch content area (~600×300); fully
  flexible, dark-theme styled, no background of its own.
- `NotesSettingsView` — add to `SettingsRootView` as a tab:
  `.tabItem { Label("Notes", systemImage: "note.text") }`.
- No closed-notch wing (Notes has no live activity).

## Startup calls

None required. `NotesStore.shared` lazily loads
`~/Library/Application Support/AgentNook/notes.json` on first access and
autosaves with a 0.5 s debounce. The store installs its own
`NSApplication.willTerminateNotification` observer to flush pending edits;
calling `NotesStore.shared.flush()` from `applicationWillTerminate` is
optional belt-and-braces.

## Keyboard / Esc behavior

- Typing requires the panel to become key. `NotchPanel.canBecomeKey == true`
  plus `becomesKeyOnlyIfNeeded` already permit this; the widget additionally
  calls `window.makeKey()` when the editor gains focus (via an internal
  window accessor), so no Core changes are needed.
- Esc inside the editor resigns first responder only — it does **not** close
  the notch, so a subsequent Esc / click-outside / hover-out closes the panel
  normally.

## Settings keys (@AppStorage, prefixed `notes.`)

- `notes.fontSize` (Double, default 13) — editor font size, 11–18 pt.
- `notes.sortOrder` (String) — `recentlyEdited` | `recentlyCreated` |
  `alphabetical`.
- `notes.selectedNoteID` (String) — internal; persists the selected note
  across open/close.

## Public types

`NotesItem`, `NotesSortOrder`, `NotesStore` (`.shared`), `NotesWidgetView`,
`NotesSettingsView`. All helpers are private.

## Permissions / Info.plist

None.
