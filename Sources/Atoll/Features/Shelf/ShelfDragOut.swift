import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Interaction overlay (drag-out + clicks + context menu)

/// Transparent AppKit overlay for a shelf tile. SwiftUI `.onDrag` is unreliable
/// from a nonactivating panel, so drags out are driven by an NSView conforming
/// to NSDraggingSource (3 pt threshold, `.fileURL` + `.string` pasteboard items,
/// ImageRenderer preview, security scope held for the drag's lifetime).
/// Also forwards clicks (with modifiers) for selection and serves the context menu.
struct ShelfItemInteractionView: NSViewRepresentable {
    var itemsForDrag: @MainActor () -> [ShelfItem]
    var dragPreview: @MainActor (ShelfItem) -> NSImage?
    var menuProvider: @MainActor (NSView) -> NSMenu?
    var onClick: @MainActor (NSEvent.ModifierFlags) -> Void
    var onDoubleClick: @MainActor () -> Void
    var onDragEnded: @MainActor (NSDragOperation, [UUID]) -> Void

    func makeNSView(context: Context) -> ShelfDragSourceNSView {
        let view = ShelfDragSourceNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: ShelfDragSourceNSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: ShelfDragSourceNSView) {
        view.itemsForDrag = itemsForDrag
        view.dragPreview = dragPreview
        view.menuProvider = menuProvider
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onDragEnded = onDragEnded
    }
}

final class ShelfDragSourceNSView: NSView, NSDraggingSource {
    var itemsForDrag: @MainActor () -> [ShelfItem] = { [] }
    var dragPreview: @MainActor (ShelfItem) -> NSImage? = { _ in nil }
    var menuProvider: @MainActor (NSView) -> NSMenu? = { _ in nil }
    var onClick: @MainActor (NSEvent.ModifierFlags) -> Void = { _ in }
    var onDoubleClick: @MainActor () -> Void = {}
    var onDragEnded: @MainActor (NSDragOperation, [UUID]) -> Void = { _, _ in }

    private var mouseDownEvent: NSEvent?
    private var scopedURLs: [URL] = []
    private var draggedItemIDs: [UUID] = []

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        // Intentionally not calling super: keep the event for click-vs-drag disambiguation.
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downEvent = mouseDownEvent else { return }
        let start = downEvent.locationInWindow
        let current = event.locationInWindow
        // 3 pt threshold before a drag session starts.
        guard hypot(current.x - start.x, current.y - start.y) > 3 else { return }
        mouseDownEvent = nil
        beginDrag(with: downEvent)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard mouseDownEvent != nil else { return }
        if event.clickCount >= 2 {
            onDoubleClick()
        } else {
            onClick(event.modifierFlags)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider(self)
    }

    // MARK: Drag session

    private func beginDrag(with event: NSEvent) {
        let dragItems = itemsForDrag()
        guard !dragItems.isEmpty else { return }

        let store = ShelfStore.shared
        var draggingItems: [NSDraggingItem] = []
        scopedURLs = []
        draggedItemIDs = []

        let location = convert(event.locationInWindow, from: nil)

        for (index, item) in dragItems.enumerated() {
            let pasteboardItem = NSPasteboardItem()
            switch item.kind {
            case .file:
                guard let scoped = store.securityScopedURL(for: item) else { continue }
                if scoped.didStartScope { scopedURLs.append(scoped.url) }
                pasteboardItem.setString(scoped.url.absoluteString, forType: .fileURL)
                pasteboardItem.setString(scoped.url.path, forType: .string)
            case .link(let url):
                pasteboardItem.setString(url.absoluteString, forType: .URL)
                pasteboardItem.setString(url.absoluteString, forType: .string)
            case .text(let string):
                pasteboardItem.setString(string, forType: .string)
            }

            let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
            let image = dragPreview(item) ?? NSWorkspace.shared.icon(for: .data)
            var size = image.size
            if size.width < 1 || size.height < 1 { size = CGSize(width: 64, height: 64) }
            // Fan multiple items out slightly under the cursor.
            let offset = CGFloat(index) * 5
            let frame = CGRect(
                x: location.x - size.width / 2 + offset,
                y: location.y - size.height / 2 - offset,
                width: size.width,
                height: size.height
            )
            draggingItem.setDraggingFrame(frame, contents: image)
            draggingItems.append(draggingItem)
            draggedItemIDs.append(item.id)
        }

        guard !draggingItems.isEmpty else { return }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication:
            return [.copy, .move]
        default:
            return [.copy]
        }
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
        scopedURLs = []
        let ids = draggedItemIDs
        draggedItemIDs = []
        onDragEnded(operation, ids)
    }
}

// MARK: - Drag preview tile

/// Small SwiftUI view rendered to an NSImage (via ImageRenderer) as drag preview.
struct ShelfDragPreviewTile: View {
    let item: ShelfItem
    let thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: item.symbolName)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: 52, height: 52)

            Text(item.displayName)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(8)
        .frame(width: 88)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
    }
}

// MARK: - Context menu plumbing

/// NSMenuItem.target is weak — this object is retained by ShelfContextMenu so
/// closure-backed menu items keep working.
final class ShelfMenuItemTarget: NSObject {
    private let handler: @MainActor () -> Void

    init(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @objc func fire(_ sender: Any?) {
        MainActor.assumeIsolated {
            handler()
        }
    }
}

/// NSMenu that retains closure targets for its items.
final class ShelfContextMenu: NSMenu {
    private var retainedTargets: [ShelfMenuItemTarget] = []

    func addAction(title: String, isEnabled: Bool = true, handler: @escaping @MainActor () -> Void) {
        let target = ShelfMenuItemTarget(handler)
        retainedTargets.append(target)
        let item = NSMenuItem(title: title, action: #selector(ShelfMenuItemTarget.fire(_:)), keyEquivalent: "")
        item.target = target
        item.isEnabled = isEnabled
        addItem(item)
    }

    func addSeparator() {
        addItem(.separator())
    }
}
