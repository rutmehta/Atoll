import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings keys

/// @AppStorage / UserDefaults keys used by the shelf feature.
enum ShelfSettingsKeys {
    static let autoRemoveAfterDrag = "shelf.autoRemoveAfterDrag"
    static let autoOpenOnDrag = "shelf.autoOpenOnDrag"
    static let clearOnQuit = "shelf.clearOnQuit"
}

// MARK: - Locations

/// On-disk locations for shelf persistence.
enum ShelfLocations {
    /// ~/Library/Application Support/Atoll
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Atoll", isDirectory: true)
    }()

    /// Copies created from raw dropped data / clipboard images live here.
    static let storageDirectory: URL = supportDirectory.appendingPathComponent("ShelfStorage", isDirectory: true)

    /// The persisted item list.
    static let storeFile: URL = supportDirectory.appendingPathComponent("shelf.json")
}

// MARK: - Store

/// Owns the shelf's items: ingestion (drops, clipboard), persistence
/// (JSON + security-scoped bookmarks in Application Support), and all
/// item actions (open, reveal, Quick Look, AirDrop, share, copy, remove).
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = []

    private static var activeSharePicker: NSSharingServicePicker?

    private init() {
        UserDefaults.standard.register(defaults: [
            ShelfSettingsKeys.autoOpenOnDrag: true,
            ShelfSettingsKeys.autoRemoveAfterDrag: false,
            ShelfSettingsKeys.clearOnQuit: false,
        ])
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: ShelfLocations.storeFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded: [ShelfItem]
        do {
            decoded = try decoder.decode([ShelfItem].self, from: data)
        } catch {
            // Never overwrite a corrupt store on the next save — quarantine it.
            NSLog("Atoll shelf: failed to decode shelf.json (\(error)); backing it up")
            let backup = ShelfLocations.storeFile.deletingPathExtension()
                .appendingPathExtension("json.corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: ShelfLocations.storeFile, to: backup)
            return
        }

        // Refresh stale bookmarks but KEEP unresolvable items — the file may
        // live on a volume that simply isn't mounted right now. Items are only
        // removed by explicit user action.
        var kept: [ShelfItem] = []
        for var item in decoded {
            if item.isFile {
                _ = resolveAndRepair(&item)
            }
            kept.append(item)
        }
        items = kept
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: ShelfLocations.supportDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: ShelfLocations.storeFile, options: .atomic)
        } catch {
            NSLog("Atoll shelf: save failed: \(error)")
        }
    }

    /// Call from applicationWillTerminate — honors the "clear on quit" setting.
    func handleAppWillTerminate() {
        if UserDefaults.standard.bool(forKey: ShelfSettingsKeys.clearOnQuit) {
            clear()
        }
    }

    // MARK: Bookmark resolution

    nonisolated private static func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a `.file` item's bookmark, refreshing stale bookmarks and
    /// repairing dead ones from the last known path. Mutates `item` in place.
    private func resolveAndRepair(_ item: inout ShelfItem) -> URL? {
        guard case .file(let bookmark) = item.kind else { return item.linkURL }
        var isStale = false
        if !bookmark.isEmpty,
           let url = try? URL(resolvingBookmarkData: bookmark,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale) {
            if isStale, let fresh = try? Self.bookmarkData(for: url) {
                item.kind = .file(bookmark: fresh)
            }
            item.filePath = url.path
            return url
        }
        // Bookmark is dead — try the last known path.
        if let path = item.filePath, FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if let fresh = try? Self.bookmarkData(for: url) {
                item.kind = .file(bookmark: fresh)
            }
            return url
        }
        return nil
    }

    /// Resolves the URL backing an item (`.file` bookmark or `.link`), patching
    /// the stored item if the bookmark needed a refresh.
    @discardableResult
    func resolveURL(for item: ShelfItem) -> URL? {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else {
            var copy = item
            return resolveAndRepair(&copy)
        }
        var copy = items[index]
        let url = resolveAndRepair(&copy)
        if copy != items[index] {
            items[index] = copy
            save()
        }
        return url
    }

    /// Resolves an item's file URL and begins security-scoped access.
    /// The caller must call `stopAccessingSecurityScopedResource()` when
    /// `didStartScope` is true.
    func securityScopedURL(for item: ShelfItem) -> (url: URL, didStartScope: Bool)? {
        guard item.isFile, let url = resolveURL(for: item) else { return nil }
        return (url, url.startAccessingSecurityScopedResource())
    }

    // MARK: Adding items

    func addFile(at url: URL, isStoredCopy: Bool = false) {
        let standardized = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else { return }
        let bookmark = (try? Self.bookmarkData(for: standardized)) ?? Data()
        let item = ShelfItem(kind: .file(bookmark: bookmark),
                             displayName: standardized.lastPathComponent,
                             filePath: standardized.path,
                             isStoredCopy: isStoredCopy)
        insert(item)
    }

    func addLink(_ url: URL) {
        insert(ShelfItem(kind: .link(url: url), displayName: ShelfItem.displayName(forLink: url)))
    }

    func addText(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        insert(ShelfItem(kind: .text(string: trimmed), displayName: ShelfItem.displayName(forText: trimmed)))
    }

    /// Adds text, promoting a lone http(s) URL to a `.link` item.
    func addTextOrLink(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !trimmed.contains(where: \.isNewline), !trimmed.contains(" "),
           let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            addLink(url)
        } else {
            addText(trimmed)
        }
    }

    /// Stores raw dropped data as a file in shelf storage and adds it.
    func addData(_ data: Data, typeIdentifier: String?, suggestedName: String?) {
        guard !data.isEmpty else { return }
        let type = typeIdentifier.flatMap { UTType($0) }
        let ext = type?.preferredFilenameExtension ?? "bin"
        let baseName: String
        if let suggestedName, !suggestedName.isEmpty {
            baseName = (suggestedName as NSString).deletingPathExtension
        } else {
            baseName = "Dropped \(Self.timestampString())"
        }
        if let url = Self.writeStorageFile(data, baseName: baseName, fileExtension: ext) {
            addFile(at: url, isStoredCopy: true)
        }
    }

    /// Dedup by identityKey: re-adding an existing item just bumps it to the front.
    private func insert(_ item: ShelfItem) {
        if let existing = items.firstIndex(where: { $0.identityKey == item.identityKey }) {
            var updated = items.remove(at: existing)
            updated.addedAt = Date()
            items.insert(updated, at: 0)
        } else {
            items.insert(item, at: 0)
        }
        save()
    }

    // MARK: Removal

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        for item in removed { deleteStoredCopyIfNeeded(item) }
        save()
    }

    func remove(_ item: ShelfItem) {
        remove(ids: [item.id])
    }

    func clear() {
        remove(ids: Set(items.map(\.id)))
    }

    private func deleteStoredCopyIfNeeded(_ item: ShelfItem) {
        guard item.isStoredCopy,
              let path = item.filePath,
              path.hasPrefix(ShelfLocations.storageDirectory.path) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: Ingestion from NSItemProvider (drops)

    /// Ingest dropped providers using the fileURL → url → text → raw-data chain.
    func ingest(_ providers: [NSItemProvider]) {
        for provider in providers {
            Task { [weak self] in
                await self?.ingest(provider: provider)
            }
        }
    }

    private func ingest(provider: NSItemProvider) async {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await Self.loadURL(from: provider, type: .fileURL) {
            addFile(at: url)
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await Self.loadURL(from: provider, type: .url) {
            if url.isFileURL {
                addFile(at: url)
            } else {
                addLink(url)
            }
            return
        }
        if let text = await Self.loadString(from: provider) {
            addTextOrLink(text)
            return
        }
        if let typeID = provider.registeredTypeIdentifiers.first,
           let data = await Self.loadData(from: provider, typeIdentifier: typeID) {
            addData(data, typeIdentifier: typeID, suggestedName: provider.suggestedName)
        }
    }

    // MARK: Provider extraction helpers (shared with AirDropZoneView)

    nonisolated static func loadURL(from provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let string = item as? String, let url = URL(string: string) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    nonisolated static func loadString(from provider: NSItemProvider) async -> String? {
        for type in [UTType.utf8PlainText, UTType.plainText]
        where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            let string: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                    if let string = item as? String {
                        continuation.resume(returning: string)
                    } else if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
                        continuation.resume(returning: string)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let string, !string.isEmpty { return string }
        }
        return nil
    }

    nonisolated static func loadData(from provider: NSItemProvider, typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: Clipboard

    /// Adds clipboard contents: file URLs, then images (stored as PNG),
    /// then web URLs, then plain text.
    func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            for url in urls { addFile(at: url) }
            return
        }

        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            if let url = Self.writeStorageFile(png, baseName: "Pasted Image \(Self.timestampString())", fileExtension: "png") {
                addFile(at: url, isStoredCopy: true)
            }
            return
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first, !first.isFileURL {
            addLink(first)
            return
        }

        if let string = pasteboard.string(forType: .string) {
            addTextOrLink(string)
        }
    }

    /// Copies items to the general pasteboard (file URLs, link URLs, strings).
    func copyToPasteboard(_ itemsToCopy: [ShelfItem]) {
        guard !itemsToCopy.isEmpty else { return }
        var objects: [NSPasteboardWriting] = []
        for item in itemsToCopy {
            switch item.kind {
            case .file:
                if let url = resolveURL(for: item) { objects.append(url as NSURL) }
            case .link(let url):
                objects.append(url as NSURL)
            case .text(let string):
                objects.append(string as NSString)
            }
        }
        guard !objects.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(objects)
    }

    // MARK: Item actions

    func open(_ itemsToOpen: [ShelfItem]) {
        for item in itemsToOpen {
            switch item.kind {
            case .file:
                guard let scoped = securityScopedURL(for: item) else { continue }
                NSWorkspace.shared.open(scoped.url)
                if scoped.didStartScope {
                    let url = scoped.url
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
            case .link(let url):
                NSWorkspace.shared.open(url)
            case .text:
                break
            }
        }
    }

    func revealInFinder(_ itemsToReveal: [ShelfItem]) {
        let urls = itemsToReveal.compactMap { $0.isFile ? resolveURL(for: $0) : nil }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// URLs suitable for QLPreviewPanel. Text items get a temp .txt file.
    func quickLookURLs(for itemsToPreview: [ShelfItem]) -> [URL] {
        itemsToPreview.compactMap { item in
            switch item.kind {
            case .file:
                return resolveURL(for: item)
            case .link(let url):
                return url
            case .text(let string):
                return Self.temporaryTextFile(string, name: item.displayName)
            }
        }
    }

    func airDrop(_ itemsToSend: [ShelfItem]) {
        var payload: [Any] = []
        var scoped: [URL] = []
        for item in itemsToSend {
            switch item.kind {
            case .file:
                if let result = securityScopedURL(for: item) {
                    if result.didStartScope { scoped.append(result.url) }
                    payload.append(result.url)
                }
            case .link(let url):
                payload.append(url)
            case .text(let string):
                payload.append(string as NSString)
            }
        }
        ShelfAirDropper.shared.airDrop(items: payload, scopedURLs: scoped)
    }

    func share(_ itemsToShare: [ShelfItem], relativeTo view: NSView) {
        var payload: [Any] = []
        for item in itemsToShare {
            switch item.kind {
            case .file:
                if let url = resolveURL(for: item) { payload.append(url) }
            case .link(let url):
                payload.append(url)
            case .text(let string):
                payload.append(string as NSString)
            }
        }
        guard !payload.isEmpty else { return }
        let picker = NSSharingServicePicker(items: payload)
        Self.activeSharePicker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    // MARK: File helpers

    nonisolated private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }

    nonisolated private static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "Item" : String(cleaned.prefix(80))
    }

    /// Writes data into shelf storage with a unique, sanitized filename.
    nonisolated static func writeStorageFile(_ data: Data, baseName: String, fileExtension: String) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: ShelfLocations.storageDirectory, withIntermediateDirectories: true)
            let base = sanitizeFilename(baseName)
            var url = ShelfLocations.storageDirectory
                .appendingPathComponent(base)
                .appendingPathExtension(fileExtension)
            var counter = 2
            while fm.fileExists(atPath: url.path) {
                url = ShelfLocations.storageDirectory
                    .appendingPathComponent("\(base) \(counter)")
                    .appendingPathExtension(fileExtension)
                counter += 1
            }
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            NSLog("Atoll shelf: failed to store dropped data: \(error)")
            return nil
        }
    }

    /// Writes a text snippet to a temp file so Quick Look can preview it.
    nonisolated static func temporaryTextFile(_ string: String, name: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AtollQuickLook", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir
                .appendingPathComponent(sanitizeFilename(name))
                .appendingPathExtension("txt")
            try string.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
