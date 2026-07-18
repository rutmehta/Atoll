import SwiftUI
import Combine

// MARK: - Model

/// A single to-do item.
struct TodoItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var done: Bool
    var favorite: Bool
    let createdAt: Date
    var completedAt: Date?

    init(id: UUID = UUID(),
         title: String,
         done: Bool = false,
         favorite: Bool = false,
         createdAt: Date = Date(),
         completedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.done = done
        self.favorite = favorite
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

// MARK: - Store

/// Owns the to-do list: JSON persistence in Application Support and
/// automatic archiving of completed items after a configurable delay.
@MainActor
final class TodosStore: ObservableObject {
    static let shared = TodosStore()

    /// Active (non-archived) items. Completed items stay here — struck
    /// through — until the auto-archive sweep moves them to `archived`.
    @Published private(set) var todos: [TodoItem] = []
    /// Auto-archived (or never manually deleted) completed items.
    @Published private(set) var archived: [TodoItem] = []

    // MARK: Derived

    var openCount: Int { todos.lazy.filter { !$0.done }.count }
    var doneCount: Int { todos.lazy.filter { $0.done }.count }

    /// Display order: favorites first, open before done, newest first.
    var sortedTodos: [TodoItem] {
        todos.sorted { a, b in
            if a.favorite != b.favorite { return a.favorite }
            if a.done != b.done { return !a.done }
            return a.createdAt > b.createdAt
        }
    }

    /// Most recently completed first.
    var sortedArchived: [TodoItem] {
        archived.sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
    }

    // MARK: Mutations

    /// Adds a new open to-do. Whitespace-only titles are ignored.
    func add(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        todos.append(TodoItem(title: trimmed))
        save()
    }

    func toggleDone(_ id: UUID) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].done.toggle()
        todos[index].completedAt = todos[index].done ? Date() : nil
        save()
    }

    func toggleFavorite(_ id: UUID) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].favorite.toggle()
        save()
    }

    func delete(_ id: UUID) {
        todos.removeAll { $0.id == id }
        save()
    }

    /// Moves an archived item back into the active list as an open to-do.
    func restore(_ id: UUID) {
        guard let index = archived.firstIndex(where: { $0.id == id }) else { return }
        var item = archived.remove(at: index)
        item.done = false
        item.completedAt = nil
        todos.append(item)
        save()
    }

    func deleteArchived(_ id: UUID) {
        archived.removeAll { $0.id == id }
        save()
    }

    func clearArchive() {
        guard !archived.isEmpty else { return }
        archived.removeAll()
        save()
    }

    /// Moves completed items older than the configured delay into the archive.
    /// Runs on launch, every minute, and after settings changes.
    func archiveSweep(now: Date = Date()) {
        let hours = autoArchiveHours
        guard hours > 0 else { return }
        let cutoff = now.addingTimeInterval(-hours * 3600)
        let expired = todos.filter { $0.done && ($0.completedAt ?? now) <= cutoff }
        guard !expired.isEmpty else { return }
        let expiredIDs = Set(expired.map(\.id))
        todos.removeAll { expiredIDs.contains($0.id) }
        archived.append(contentsOf: expired)
        save()
    }

    // MARK: Settings

    /// Mirrors the `@AppStorage("todos.autoArchiveHours")` setting.
    /// `0` (or negative) disables auto-archiving.
    private var autoArchiveHours: Double {
        UserDefaults.standard.object(forKey: "todos.autoArchiveHours") as? Double ?? 24
    }

    // MARK: Persistence

    private struct TodosDocument: Codable {
        var active: [TodoItem]
        var archived: [TodoItem]
    }

    private let fileURL: URL
    private var sweepTimer: Timer?

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base.appendingPathComponent("AgentNook", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("todos.json")

        load()
        archiveSweep()
        startSweepTimer()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let doc = try decoder.decode(TodosDocument.self, from: data)
            todos = doc.active
            archived = doc.archived
        } catch {
            NSLog("AgentNook Todos: failed to decode todos.json (%@); backing it up and starting fresh",
                  String(describing: error))
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(TodosDocument(active: todos, archived: archived))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("AgentNook Todos: save failed: %@", String(describing: error))
        }
    }

    private func startSweepTimer() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.archiveSweep()
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
    }
}
