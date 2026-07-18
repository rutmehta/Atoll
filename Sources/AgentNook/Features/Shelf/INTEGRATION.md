# Features/Shelf — Integration

## Views

| View | Placement |
|---|---|
| `ShelfView` | The **Shelf tab** content in `OpenNotchView` (replace the `PlaceholderPane` for `case .shelf`). Fills the tab area; includes the AirDrop zone on its left edge. |
| `AirDropZoneView` | Already embedded inside `ShelfView`. Also usable standalone (e.g. a drop wing) — give it a frame and optionally `onActivate` for click-to-AirDrop. |
| `ShelfSettingsView` | Add as a "Shelf" tab/section in the settings window. |

No closed-notch wing is provided by this module (the shelf has no persistent live activity; the drag detector below handles the closed-notch interaction).

## Startup calls (AppDelegate / app launch)

```swift
// 1. Load persisted shelf items (also registers shelf settings defaults).
_ = ShelfStore.shared

// 2. Auto-open the shelf when the user drags content toward the notch:
DragDetector.shared.onDragNearNotch = { [weak vm] in
    vm?.open(tab: .shelf)          // vm is the NotchViewModel for the screen
}
DragDetector.shared.start()
```

`DragDetector` fires at most once per drag, only while something is actually on
the drag pasteboard (files / URLs / text / images), only inside the notch region
(notch rect widened ±100 pt, extended 24 pt downward, any screen), and only when
the `shelf.autoOpenOnDrag` setting is on. It uses global mouse monitors — **no
Accessibility permission needed**. Call `DragDetector.shared.stop()` if the user
disables the feature entirely (optional; the setting is also checked per-event).

Recommended (drop-while-closed): the whole open-notch/panel root may additionally
`.onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.isDropTargeted)`
and forward providers to `ShelfStore.shared.ingest(_:)` — ShelfView already does
this for drops landing on the shelf itself.

## Termination

```swift
func applicationWillTerminate(_ notification: Notification) {
    ShelfStore.shared.handleAppWillTerminate()   // honors "Clear shelf when quitting"
}
```

## Settings

`ShelfSettingsView` uses these `@AppStorage` keys (defaults registered by `ShelfStore`):

- `shelf.autoOpenOnDrag` (Bool, default **true**) — drag near notch opens shelf
- `shelf.autoRemoveAfterDrag` (Bool, default false) — remove items after successful drag-out
- `shelf.clearOnQuit` (Bool, default false)

## Permissions / Info.plist

None required. AirDrop, Quick Look, thumbnails, drag&drop and the global mouse
monitors all work unsandboxed without TCC prompts.

## Persistence locations

- `~/Library/Application Support/AgentNook/shelf.json` — item list (files stored as security-scoped bookmarks with stale-refresh + path-repair)
- `~/Library/Application Support/AgentNook/ShelfStorage/` — copies created from raw dropped data / pasted clipboard images (deleted when the item is removed)

## Behavior notes for the integrator

- **Keyboard shortcuts** (Space = Quick Look, Delete = remove, ⌘C copy, ⌘V paste,
  ⌘A select all) use a local `.keyDown` monitor installed while `ShelfView` is
  visible. They only work if the notch panel can receive key events; with a fully
  nonactivating panel they degrade silently (context menu covers every action).
- Quick Look uses the shared `QLPreviewPanel` with `ShelfQuickLookController.shared`
  as data source; it activates the app so the panel can become key.
- Drag-out is AppKit `NSDraggingSource` (3 pt threshold, `.fileURL` + `.string`
  pasteboard, `[.copy, .move]` outside the app, ImageRenderer previews, security
  scope held for the drag). SwiftUI `.onDrag` is not used.
- While an AirDrop/share sheet or drag is in flight, avoid force-closing the
  notch if possible (`NSSharingServicePicker` is anchored to the tile view).

## Public types exposed

`ShelfItem`, `ShelfStore` (@MainActor singleton), `ShelfView`, `AirDropZoneView`,
`ShelfSettingsView`, `ShelfSettingsKeys`, `ShelfLocations`, `DragDetector`
(@MainActor singleton), `ShelfQuickLookController`, `ShelfAirDropper`,
`ShelfThumbnailLoader`, `ShelfItemInteractionView`/`ShelfDragSourceNSView`,
`ShelfDragPreviewTile`, `ShelfContextMenu`/`ShelfMenuItemTarget`.
