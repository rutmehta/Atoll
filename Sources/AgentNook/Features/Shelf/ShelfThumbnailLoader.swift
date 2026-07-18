import AppKit
import QuickLookThumbnailing

/// Generates and caches Quick Look thumbnails for shelf file items.
/// Falls back to the Finder icon (handled by the tile view) when generation fails.
@MainActor
final class ShelfThumbnailLoader {
    static let shared = ShelfThumbnailLoader()

    private let cache = NSCache<NSString, NSImage>()
    private var failedKeys: Set<String> = []

    private init() {
        cache.countLimit = 256
    }

    func cachedThumbnail(for item: ShelfItem) -> NSImage? {
        cache.object(forKey: item.identityKey as NSString)
    }

    /// Async thumbnail via QuickLookThumbnailing; nil when unavailable
    /// (links, text, folders without previews, generation failure).
    func thumbnail(for item: ShelfItem, size: CGSize = CGSize(width: 64, height: 64)) async -> NSImage? {
        let key = item.identityKey
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard !failedKeys.contains(key) else { return nil }
        guard item.isFile, let url = ShelfStore.shared.resolveURL(for: item) else { return nil }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 2,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            failedKeys.insert(key)
            return nil
        }
        let image = representation.nsImage
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    /// Finder icon fallback for files (works for folders, apps, everything).
    func fileIcon(for item: ShelfItem) -> NSImage? {
        guard item.isFile, let path = item.filePath else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }
}
