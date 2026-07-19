import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The shelf tab: AirDrop drop zone on the left, item grid on the right.
/// Drop anything (files, links, text, raw data) anywhere on the view to add it.
struct ShelfView: View {
    @ObservedObject private var store = ShelfStore.shared

    @State private var selection: Set<UUID> = []
    @State private var selectionAnchorID: UUID?
    @State private var isStackExpanded = false
    @State private var isDropTargeted = false
    @State private var keyMonitor: Any?

    /// More items than this collapse into a stack until expanded.
    private let collapseThreshold = 6

    var body: some View {
        HStack(spacing: 10) {
            AirDropZoneView(onActivate: { store.airDrop(selectedOrAllItems) })
                .frame(width: 92)

            if store.items.isEmpty {
                emptyState
            } else {
                itemArea
            }
        }
        .padding(2)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isDropTargeted ? 0.8 : 0), lineWidth: 1.5)
        )
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL, .url, .utf8PlainText, .plainText, .image, .data],
                isTargeted: $isDropTargeted) { providers in
            store.ingest(providers)
            return true
        }
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
        .onChange(of: store.items) { _, newItems in
            let valid = Set(newItems.map(\.id))
            selection = selection.intersection(valid)
            if let anchor = selectionAnchorID, !valid.contains(anchor) {
                selectionAnchorID = nil
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.4))
            Text("Drop files here")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            Text("Files, links and text land on the shelf.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
            Button {
                store.pasteFromClipboard()
            } label: {
                Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(Color.white.opacity(0.18))
        )
    }

    // MARK: Item grid

    private var itemArea: some View {
        VStack(spacing: 6) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 82, maximum: 112), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(displayedItems) { item in
                        tile(for: item)
                    }
                    if isCollapsed {
                        stackTile
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var isCollapsed: Bool {
        store.items.count > collapseThreshold && !isStackExpanded
    }

    private var displayedItems: [ShelfItem] {
        if isCollapsed {
            return Array(store.items.prefix(collapseThreshold - 1))
        }
        return store.items
    }

    private var selectedOrAllItems: [ShelfItem] {
        let selected = store.items.filter { selection.contains($0.id) }
        return selected.isEmpty ? store.items : selected
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("\(store.items.count) item\(store.items.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))

            Spacer()

            if store.items.count > collapseThreshold {
                headerButton(
                    systemImage: isStackExpanded ? "square.stack.3d.up" : "square.grid.2x2",
                    help: isStackExpanded ? "Collapse into stack" : "Show all items"
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        isStackExpanded.toggle()
                    }
                }
            }
            headerButton(systemImage: "doc.on.clipboard", help: "Paste from clipboard") {
                store.pasteFromClipboard()
            }
            headerButton(systemImage: "trash", help: "Clear shelf") {
                selection = []
                store.clear()
            }
        }
        .padding(.horizontal, 2)
    }

    private func headerButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Tiles

    private func tile(for item: ShelfItem) -> some View {
        ShelfTileView(item: item, isSelected: selection.contains(item.id))
            .overlay(
                ShelfItemInteractionView(
                    itemsForDrag: { dragItems(for: item) },
                    dragPreview: { dragPreviewImage(for: $0) },
                    menuProvider: { anchor in contextMenu(for: item, anchor: anchor) },
                    onClick: { modifiers in handleClick(on: item, modifiers: modifiers) },
                    onDoubleClick: { store.open([item]) },
                    onDragEnded: { operation, ids in handleDragEnded(operation: operation, ids: ids) }
                )
            )
            .help(item.displayName)
    }

    private var stackTile: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                isStackExpanded = true
            }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .frame(width: 54, height: 54)
                        .rotationEffect(.degrees(-7))
                        .offset(x: -3, y: 2)
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 54, height: 54)
                        .rotationEffect(.degrees(5))
                        .offset(x: 3, y: 1)
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 54, height: 54)
                    Text("+\(store.items.count - (collapseThreshold - 1))")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 58, height: 58)

                Text("Show all")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(5)
        }
        .buttonStyle(.plain)
        .help("Expand the stack")
    }

    // MARK: Selection

    private func handleClick(on item: ShelfItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(item.id) {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
                selectionAnchorID = item.id
            }
        } else if modifiers.contains(.shift),
                  let anchorID = selectionAnchorID,
                  let anchorIndex = displayedItems.firstIndex(where: { $0.id == anchorID }),
                  let clickIndex = displayedItems.firstIndex(where: { $0.id == item.id }) {
            let range = min(anchorIndex, clickIndex)...max(anchorIndex, clickIndex)
            selection = Set(displayedItems[range].map(\.id))
        } else {
            selection = [item.id]
            selectionAnchorID = item.id
        }
    }

    /// Dragging a selected tile drags the whole selection; dragging an
    /// unselected tile drags (and selects) just that item.
    private func dragItems(for item: ShelfItem) -> [ShelfItem] {
        if selection.contains(item.id) {
            return store.items.filter { selection.contains($0.id) }
        }
        selection = [item.id]
        selectionAnchorID = item.id
        return [item]
    }

    private func handleDragEnded(operation: NSDragOperation, ids: [UUID]) {
        guard operation != [],
              UserDefaults.standard.bool(forKey: ShelfSettingsKeys.autoRemoveAfterDrag) else { return }
        removeItems(Set(ids))
    }

    private func removeItems(_ ids: Set<UUID>) {
        selection.subtract(ids)
        store.remove(ids: ids)
    }

    // MARK: Context menu

    private func targetItems(for item: ShelfItem) -> [ShelfItem] {
        if selection.contains(item.id) {
            return store.items.filter { selection.contains($0.id) }
        }
        return [item]
    }

    private func contextMenu(for item: ShelfItem, anchor: NSView) -> NSMenu {
        let targets = targetItems(for: item)
        let menu = ShelfContextMenu()
        menu.autoenablesItems = false

        menu.addAction(title: "Open", isEnabled: targets.contains { !$0.isText }) {
            store.open(targets)
        }
        menu.addAction(title: "Quick Look") {
            ShelfQuickLookController.shared.show(urls: store.quickLookURLs(for: targets))
        }
        menu.addAction(title: "Reveal in Finder", isEnabled: targets.contains(where: \.isFile)) {
            store.revealInFinder(targets)
        }
        menu.addSeparator()
        menu.addAction(title: "AirDrop") {
            store.airDrop(targets)
        }
        menu.addAction(title: "Share…") { [weak anchor] in
            guard let anchor else { return }
            store.share(targets, relativeTo: anchor)
        }
        menu.addSeparator()
        menu.addAction(title: "Copy") {
            store.copyToPasteboard(targets)
        }
        menu.addSeparator()
        menu.addAction(title: "Remove") {
            removeItems(Set(targets.map(\.id)))
        }
        return menu
    }

    // MARK: Drag preview

    private func dragPreviewImage(for item: ShelfItem) -> NSImage? {
        let thumbnail = ShelfThumbnailLoader.shared.cachedThumbnail(for: item)
            ?? ShelfThumbnailLoader.shared.fileIcon(for: item)
        let renderer = ImageRenderer(content: ShelfDragPreviewTile(item: item, thumbnail: thumbnail))
        renderer.scale = 2
        return renderer.nsImage ?? thumbnail
    }

    // MARK: Keyboard (Space = Quick Look, Delete = remove, ⌘C/⌘V/⌘A)

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Snapshot plain values so no NSEvent crosses the isolation boundary.
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            let characters = event.charactersIgnoringModifiers
            let handled = MainActor.assumeIsolated {
                handleKeyEvent(keyCode: keyCode, modifiers: modifiers, characters: characters)
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    /// Returns true when the event was consumed.
    private func handleKeyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> Bool {
        let hasCommand = modifiers.contains(.command)
        switch keyCode {
        case 49 where !hasCommand: // Space → Quick Look
            let targets = selectedOrAllItems
            guard !targets.isEmpty else { return false }
            ShelfQuickLookController.shared.toggle(urls: store.quickLookURLs(for: targets))
            return true
        case 51, 117: // Delete / Forward Delete → remove selection
            guard !selection.isEmpty else { return false }
            removeItems(selection)
            return true
        default:
            break
        }
        if hasCommand, let characters = characters?.lowercased() {
            switch characters {
            case "c":
                let targets = store.items.filter { selection.contains($0.id) }
                guard !targets.isEmpty else { return false }
                store.copyToPasteboard(targets)
                return true
            case "v":
                store.pasteFromClipboard()
                return true
            case "a":
                selection = Set(displayedItems.map(\.id))
                return true
            default:
                break
            }
        }
        return false
    }
}

// MARK: - Tile view

private struct ShelfTileView: View {
    let item: ShelfItem
    let isSelected: Bool

    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                thumbnailContent
            }
            .frame(width: 54, height: 54)

            Text(item.displayName)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: 76)
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.75) : Color.clear, lineWidth: 1)
        )
        .task(id: item.identityKey) {
            thumbnail = await ShelfThumbnailLoader.shared.thumbnail(for: item)
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else if item.isFile, let icon = ShelfThumbnailLoader.shared.fileIcon(for: item) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
        } else {
            Image(systemName: item.symbolName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
        }
    }
}
