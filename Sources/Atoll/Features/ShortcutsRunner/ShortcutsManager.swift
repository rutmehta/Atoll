import SwiftUI
import AppKit
import Combine

// MARK: - Model

/// One user shortcut as reported by `shortcuts list`.
struct ShortcutsItem: Identifiable, Hashable {
    let name: String
    var id: String { name }
}

/// Result flash shown on a chip right after a run finishes.
enum ShortcutsRunOutcome: Equatable {
    case success
    case failure
}

/// Load status of the shortcut list.
enum ShortcutsLoadState: Equatable {
    case idle
    case loading
    case loaded
    /// The `shortcuts` command-line tool is missing from this system.
    case unavailable(String)
    /// `shortcuts list` ran but failed.
    case failed(String)
}

// MARK: - Manager

/// Lists and runs macOS Shortcuts via the `/usr/bin/shortcuts` CLI.
/// Publishes per-shortcut running state and short-lived success/failure flashes.
@MainActor
final class ShortcutsManager: ObservableObject {
    static let shared = ShortcutsManager()

    nonisolated static let cliPath = "/usr/bin/shortcuts"

    /// Every shortcut the CLI reported, in Shortcuts-app order (deduplicated).
    @Published private(set) var allShortcuts: [ShortcutsItem] = []
    @Published private(set) var loadState: ShortcutsLoadState = .idle
    /// Names currently executing via `shortcuts run`.
    @Published private(set) var runningNames: Set<String> = []
    /// Short-lived success/error flash per shortcut name (cleared automatically).
    @Published private(set) var recentOutcomes: [String: ShortcutsRunOutcome] = [:]
    /// Widget search filter.
    @Published var searchText = ""

    // Persisted as JSON arrays of shortcut names.
    @AppStorage("shortcuts.favorites") private var favoritesJSON = "[]" { willSet { objectWillChange.send() } }
    @AppStorage("shortcuts.hidden") private var hiddenJSON = "[]" { willSet { objectWillChange.send() } }

    private var flashTokens: [String: UUID] = [:]
    private var lastRefresh: Date?
    /// Skip on-appear refreshes when the list is fresher than this.
    private let refreshStaleness: TimeInterval = 20

    private init() {}

    var isLoading: Bool { loadState == .loading }

    var cliIsAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: Self.cliPath)
    }

    // MARK: Favorites

    var favoriteNames: Set<String> { Self.decodeNames(favoritesJSON) }

    func isFavorite(_ name: String) -> Bool { favoriteNames.contains(name) }

    func toggleFavorite(_ name: String) {
        var names = favoriteNames
        if !names.insert(name).inserted { names.remove(name) }
        favoritesJSON = Self.encodeNames(names)
    }

    // MARK: Hidden shortcuts (settings)

    var hiddenNames: Set<String> { Self.decodeNames(hiddenJSON) }

    func isHidden(_ name: String) -> Bool { hiddenNames.contains(name) }

    func setHidden(_ name: String, _ hidden: Bool) {
        var names = hiddenNames
        if hidden { names.insert(name) } else { names.remove(name) }
        hiddenJSON = Self.encodeNames(names)
    }

    func unhideAll() {
        hiddenJSON = "[]"
    }

    // MARK: Derived lists

    /// Shortcuts shown in the widget: hidden filtered out, search applied,
    /// favorites floated to the top, then alphabetical.
    var widgetShortcuts: [ShortcutsItem] {
        let hidden = hiddenNames
        let favorites = favoriteNames
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return allShortcuts
            .filter { !hidden.contains($0.name) }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { a, b in
                let favA = favorites.contains(a.name)
                let favB = favorites.contains(b.name)
                if favA != favB { return favA }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    /// Everything, alphabetical, for the settings list (hidden ones included).
    var settingsShortcuts: [ShortcutsItem] {
        allShortcuts.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: Listing

    /// Cheap refresh used by `.onAppear` — skips when a fresh list already exists.
    func refreshOnAppear() {
        if isLoading { return }
        if case .loaded = loadState,
           let last = lastRefresh,
           Date().timeIntervalSince(last) < refreshStaleness {
            return
        }
        refresh()
    }

    /// Re-run `shortcuts list` and replace the published list.
    func refresh() {
        guard !isLoading else { return }
        guard cliIsAvailable else {
            allShortcuts = []
            loadState = .unavailable(
                "The Shortcuts command-line tool was not found at \(Self.cliPath). It ships with macOS 12 and later."
            )
            return
        }
        loadState = .loading
        Task { [weak self] in
            let result = await ShortcutsManager.execute(arguments: ["list"])
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.loadState = .failed(error.localizedDescription)
            case .success(let run):
                if run.exitCode != 0 {
                    let stderr = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.loadState = .failed(
                        stderr.isEmpty ? "shortcuts list exited with code \(run.exitCode)." : stderr
                    )
                } else {
                    self.allShortcuts = Self.parseList(run.stdout)
                    self.loadState = .loaded
                    self.lastRefresh = Date()
                }
            }
        }
    }

    // MARK: Running

    /// Run a shortcut asynchronously; flips the per-name spinner state and
    /// flashes success/failure based on the CLI exit code.
    func run(_ item: ShortcutsItem) {
        let name = item.name
        guard !runningNames.contains(name) else { return }
        guard cliIsAvailable else {
            flash(name, outcome: .failure)
            return
        }
        recentOutcomes[name] = nil
        runningNames.insert(name)
        Task { [weak self] in
            let result = await ShortcutsManager.execute(arguments: ["run", name])
            guard let self else { return }
            self.runningNames.remove(name)
            switch result {
            case .success(let run) where run.exitCode == 0:
                self.flash(name, outcome: .success)
            case .success, .failure:
                self.flash(name, outcome: .failure)
            }
        }
    }

    private func flash(_ name: String, outcome: ShortcutsRunOutcome) {
        let token = UUID()
        flashTokens[name] = token
        withAnimation(.easeIn(duration: 0.12)) {
            recentOutcomes[name] = outcome
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self, self.flashTokens[name] == token else { return }
            self.flashTokens[name] = nil
            withAnimation(.easeOut(duration: 0.4)) {
                _ = self.recentOutcomes.removeValue(forKey: name)
            }
        }
    }

    // MARK: Shortcuts.app deep links

    func openShortcutsApp() {
        if let url = URL(string: "shortcuts://") {
            NSWorkspace.shared.open(url)
        }
    }

    func openShortcutsAppCreate() {
        if let url = URL(string: "shortcuts://create-shortcut") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Helpers

    private static func parseList(_ output: String) -> [ShortcutsItem] {
        var seen = Set<String>()
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .map(ShortcutsItem.init(name:))
    }

    private static func decodeNames(_ json: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(names)
    }

    private static func encodeNames(_ names: Set<String>) -> String {
        guard let data = try? JSONEncoder().encode(names.sorted()),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    /// Runs the shortcuts CLI off the main thread and returns exit code + output.
    nonisolated private static func execute(
        arguments: [String]
    ) async -> Result<ShortcutsProcessRun, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: cliPath)
                process.arguments = arguments
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failure(error))
                    return
                }
                // Drain pipes before waiting so large output can't deadlock.
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: .success(ShortcutsProcessRun(
                    exitCode: process.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                )))
            }
        }
    }
}

/// Exit code + captured output of one CLI invocation.
private struct ShortcutsProcessRun {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}
