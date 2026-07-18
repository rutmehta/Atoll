# Features/Todos — Integration

## Views

| View | Placement |
|---|---|
| `TodosWidgetView` | Open notch, **Tools** tab (grid cell alongside mirror/timer/notes/shortcuts). Flexible: fills whatever frame the grid gives it; content scrolls. Dark-notch styled (white text on black). |
| `TodoCountWing` | Closed-notch **wing** (either side). Height-flexible (`maxHeight: .infinity`, fits the ~28-36 pt notch height). Renders **nothing** when there are no open to-dos, so it can be composed unconditionally; give it lower priority than media/HUD wings. |
| `TodosSettingsView` | Settings window, "To-dos" tab/section. Standard system `Form` styling (not dark-forced). |

## Startup

Optional but recommended in `AppDelegate.applicationDidFinishLaunching`:

```swift
_ = TodosStore.shared
```

This loads persisted to-dos and starts the 60 s auto-archive sweep timer immediately
(otherwise both happen lazily the first time any Todos view appears).

## Model / store

- `TodosStore.shared` (`@MainActor ObservableObject`) — published `todos` / `archived`,
  `sortedTodos` (favorites first, open before done, newest first), `openCount`,
  `add / toggleDone / toggleFavorite / delete / restore / deleteArchived / clearArchive / archiveSweep`.
- `TodoItem` — `id, title, done, favorite, createdAt, completedAt`.

## Persistence

`~/Library/Application Support/AgentNook/todos.json` (atomic writes, ISO-8601 dates).
A corrupt file is renamed to `todos.json.corrupt` instead of being overwritten.

## Settings keys (`@AppStorage`)

- `todos.autoArchiveHours` (Double, default 24; `0` = never) — delay before completed items move to archive.
- `todos.showArchived` (Bool, default true) — show the collapsible archive section in the widget.

## Permissions / Info.plist

None.

## Integrator note

The quick-add `TextField` needs keyboard focus: the notch `NSPanel` must be able to
become key (`canBecomeKey == true`) while the nook is open, or typing will go to the
previously focused app.
