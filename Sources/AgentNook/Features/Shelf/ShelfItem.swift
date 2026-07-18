import AppKit
import UniformTypeIdentifiers

/// One entry in the shelf tray: a file (persisted as a security-scoped bookmark),
/// a web link, or a snippet of plain text.
struct ShelfItem: Identifiable, Codable, Equatable {

    enum Kind: Codable, Equatable {
        /// A file or folder on disk, persisted as a security-scoped bookmark.
        case file(bookmark: Data)
        /// A non-file URL.
        case link(url: URL)
        /// A snippet of plain text.
        case text(string: String)
    }

    let id: UUID
    var kind: Kind
    /// User-visible name (filename for files, host for links, first line for text).
    var displayName: String
    var addedAt: Date
    /// Last known absolute path for `.file` items — used for dedup and bookmark repair.
    var filePath: String?
    /// True when the file lives in AgentNook's own shelf storage (created from raw
    /// dropped data or the clipboard) and should be deleted from disk on removal.
    var isStoredCopy: Bool

    init(id: UUID = UUID(),
         kind: Kind,
         displayName: String,
         addedAt: Date = Date(),
         filePath: String? = nil,
         isStoredCopy: Bool = false) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.addedAt = addedAt
        self.filePath = filePath
        self.isStoredCopy = isStoredCopy
    }

    // MARK: Convenience

    var isFile: Bool {
        if case .file = kind { return true }
        return false
    }

    var isText: Bool {
        if case .text = kind { return true }
        return false
    }

    var linkURL: URL? {
        if case .link(let url) = kind { return url }
        return nil
    }

    var textContent: String? {
        if case .text(let string) = kind { return string }
        return nil
    }

    /// SF Symbol used when no thumbnail is available.
    var symbolName: String {
        switch kind {
        case .file:
            return "doc"
        case .link:
            return "link"
        case .text:
            return "text.alignleft"
        }
    }

    /// The UTType of a `.file` item, derived from its extension.
    var fileUTType: UTType? {
        guard case .file = kind, let path = filePath else { return nil }
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)
    }

    /// Stable identity used to deduplicate items added twice.
    var identityKey: String {
        switch kind {
        case .file:
            return "file:" + (filePath?.lowercased() ?? id.uuidString)
        case .link(let url):
            return "link:" + url.absoluteString
        case .text(let string):
            return "text:" + String(Self.stableHash(string), radix: 16)
        }
    }

    // MARK: Helpers

    /// FNV-1a — stable across launches (unlike `hashValue`), so persisted text
    /// items still dedup correctly after a restart.
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    static func displayName(forText text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Text snippet" }
        return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
    }

    static func displayName(forLink url: URL) -> String {
        url.host ?? url.absoluteString
    }
}
