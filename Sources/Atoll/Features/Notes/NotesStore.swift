import AppKit
import Combine
import Foundation

// MARK: - Model

/// A single quick note kept in the notch.
struct NotesItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), text: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// First non-empty line, used as the list preview / pseudo-title.
    var firstLinePreview: String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return "New Note"
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Sort order

enum NotesSortOrder: String, CaseIterable, Identifiable {
    case recentlyEdited
    case recentlyCreated
    case alphabetical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recentlyEdited: return "Recently Edited"
        case .recentlyCreated: return "Recently Created"
        case .alphabetical: return "Title (A–Z)"
        }
    }

    func sorted(_ notes: [NotesItem]) -> [NotesItem] {
        switch self {
        case .recentlyEdited:
            return notes.sorted { $0.updatedAt > $1.updatedAt }
        case .recentlyCreated:
            return notes.sorted { $0.createdAt > $1.createdAt }
        case .alphabetical:
            return notes.sorted {
                $0.firstLinePreview.localizedCaseInsensitiveCompare($1.firstLinePreview) == .orderedAscending
            }
        }
    }
}

// MARK: - Store

/// Owns all quick notes. JSON persistence in
/// `~/Library/Application Support/Atoll/notes.json` with a 0.5 s
/// debounced autosave. All access is main-actor.
@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published private(set) var notes: [NotesItem] = []

    let fileURL: URL

    private var saveTask: Task<Void, Never>?
    private var dirty = false
    private var terminationObserver: NSObjectProtocol?

    private static let saveDebounce: TimeInterval = 0.5

    init(fileURL: URL = NotesStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()

        // Best-effort flush when the app quits so the debounce window can't
        // drop the last edit.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flush()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    nonisolated static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Atoll", isDirectory: true)
            .appendingPathComponent("notes.json", isDirectory: false)
    }

    // MARK: Queries

    func note(id: UUID?) -> NotesItem? {
        guard let id else { return nil }
        return notes.first { $0.id == id }
    }

    // MARK: Mutations

    @discardableResult
    func createNote(text: String = "") -> NotesItem {
        let note = NotesItem(text: text)
        notes.insert(note, at: 0)
        scheduleSave()
        return note
    }

    func deleteNote(id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes.remove(at: index)
        scheduleSave()
    }

    @discardableResult
    func duplicateNote(id: UUID) -> NotesItem? {
        guard let original = note(id: id) else { return nil }
        let copy = NotesItem(text: original.text)
        notes.insert(copy, at: 0)
        scheduleSave()
        return copy
    }

    /// Updates a note's text (no-op when unchanged) and bumps `updatedAt`.
    func updateText(_ text: String, for id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }),
              notes[index].text != text else { return }
        notes[index].text = text
        notes[index].updatedAt = Date()
        scheduleSave()
    }

    // MARK: Persistence

    /// Saves immediately if there are unsaved changes. Safe to call any time.
    func flush() {
        guard dirty else { return }
        saveNow()
    }

    /// Ensures the backing file exists, then shows it in Finder.
    func revealInFinder() {
        if dirty || !FileManager.default.fileExists(atPath: fileURL.path) {
            saveNow()
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func scheduleSave() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.saveDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(NotesFile(version: 1, notes: notes))
            try data.write(to: fileURL, options: .atomic)
            dirty = false
        } catch {
            NSLog("Atoll Notes: save failed: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let file = try? decoder.decode(NotesFile.self, from: data) {
                notes = file.notes
            } else {
                // Fallback: bare array written by an earlier format.
                notes = try decoder.decode([NotesItem].self, from: data)
            }
        } catch {
            NSLog("Atoll Notes: load failed, keeping corrupt file aside: \(error)")
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            notes = []
        }
    }
}

/// On-disk envelope so the format can evolve without breaking old files.
private struct NotesFile: Codable {
    var version: Int
    var notes: [NotesItem]
}
