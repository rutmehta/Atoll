import Foundation
import Combine

/// Install status for one provider's hook config.
enum AgentHookInstallState: String {
    case notInstalled
    case partial
    case installed
}

/// Opt-in installer for the Atoll hook script into
/// `~/.claude/settings.json` (respecting `$CLAUDE_CONFIG_DIR`) and
/// `~/.codex/hooks.json`.
///
/// - Idempotent upsert: our entries are recognized by the "atoll" marker in
///   the command path; existing user entries are always preserved (JSON is
///   parsed and round-tripped, unknown keys untouched).
/// - Uninstall prunes ONLY entries whose command contains the marker.
/// - NEVER runs automatically — the UI must call `install()` from a button.
@MainActor
final class AgentHookInstaller: ObservableObject {
    static let shared = AgentHookInstaller()

    @Published private(set) var claudeState: AgentHookInstallState = .notInstalled
    @Published private(set) var codexState: AgentHookInstallState = .notInstalled
    @Published private(set) var lastError: String?

    var overallState: AgentHookInstallState {
        switch (claudeState, codexState) {
        case (.installed, .installed): return .installed
        case (.notInstalled, .notInstalled): return .notInstalled
        default: return .partial
        }
    }

    enum InstallerError: LocalizedError {
        case unparseableConfig(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unparseableConfig(let path):
                return "Could not parse \(path) — refusing to modify it. Fix or move the file and retry."
            case .writeFailed(let path):
                return "Could not write \(path)."
            }
        }
    }

    // MARK: - Paths

    /// Where the hook script is written. Contains the marker "atoll" in the
    /// path, which is what install/uninstall/status detection keys on.
    /// Deliberately a space-free path (NOT "Application Support") — hook commands
    /// run through `sh -c` and a space in an unquoted path breaks execution.
    nonisolated static var scriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".atoll", isDirectory: true)
            .appendingPathComponent(AgentHookScript.scriptFileName)
    }

    nonisolated static var claudeSettingsURL: URL {
        let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        return dir.appendingPathComponent("settings.json")
    }

    nonisolated static var codexHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    // MARK: - Event tables

    /// Claude Code events we register, with their matcher groups (nil = no matcher key).
    /// Notification matchers are the official attention signals (research-critic).
    private nonisolated static let claudeEvents: [(event: String, matchers: [String?])] = [
        ("SessionStart", [nil]),
        ("UserPromptSubmit", [nil]),
        ("PreToolUse", ["*"]),
        ("PostToolUse", ["*"]),
        ("PostToolUseFailure", ["*"]),
        ("PermissionRequest", ["*"]),
        ("PreCompact", ["auto", "manual"]),
        ("Stop", [nil]),
        ("SubagentStop", [nil]),
        ("SessionEnd", [nil]),
        ("Notification", ["agent_needs_input|agent_completed|permission_prompt"]),
    ]

    /// Codex hook events (Codex ships ~10 events now; these are the ones we consume).
    /// Codex hooks are enabled by default — no config.toml feature flag is touched.
    private nonisolated static let codexEvents: [String] = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop",
    ]

    // Quoted defensively even though the path is space-free.
    private nonisolated static var claudeCommand: String { "\"\(scriptURL.path)\" claude" }
    private nonisolated static var codexCommand: String { "\"\(scriptURL.path)\" codex" }

    // MARK: - Status

    func refreshStatus() {
        claudeState = Self.claudeStatus()
        codexState = Self.codexStatus()
    }

    private nonisolated static func claudeStatus() -> AgentHookInstallState {
        guard let root = readJSONObject(at: claudeSettingsURL),
              let hooks = root["hooks"] as? [String: Any] else { return .notInstalled }
        var found = 0
        for (event, _) in claudeEvents {
            if eventArrayContainsMarker(hooks[event]) { found += 1 }
        }
        if found == 0 { return .notInstalled }
        let scriptExists = FileManager.default.fileExists(atPath: scriptURL.path)
        return (found == claudeEvents.count && scriptExists) ? .installed : .partial
    }

    private nonisolated static func codexStatus() -> AgentHookInstallState {
        guard let root = readJSONObject(at: codexHooksURL),
              let hooks = root["hooks"] as? [String: Any] else { return .notInstalled }
        var found = 0
        for event in codexEvents {
            if eventArrayContainsMarker(hooks[event]) { found += 1 }
        }
        if found == 0 { return .notInstalled }
        let scriptExists = FileManager.default.fileExists(atPath: scriptURL.path)
        return (found == codexEvents.count && scriptExists) ? .installed : .partial
    }

    /// Does any matcher group in this event's array contain a hook command with our marker?
    private nonisolated static func eventArrayContainsMarker(_ value: Any?) -> Bool {
        guard let groups = value as? [[String: Any]] else { return false }
        for group in groups {
            guard let inner = group["hooks"] as? [[String: Any]] else { continue }
            for hook in inner {
                if let cmd = hook["command"] as? String, cmd.contains(AgentHookScript.marker) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Install

    func install() {
        lastError = nil
        do {
            try Self.writeScript()
            try Self.upsertClaude()
            try Self.upsertCodex()
        } catch {
            lastError = error.localizedDescription
            NSLog("Atoll: hook install failed: \(error.localizedDescription)")
        }
        refreshStatus()
    }

    func uninstall() {
        lastError = nil
        do {
            try Self.pruneOurEntries(at: Self.claudeSettingsURL)
            try Self.pruneOurEntries(at: Self.codexHooksURL)
            // The script itself is harmless without registrations, but clean up anyway.
            try? FileManager.default.removeItem(at: Self.scriptURL)
        } catch {
            lastError = error.localizedDescription
            NSLog("Atoll: hook uninstall failed: \(error.localizedDescription)")
        }
        refreshStatus()
    }

    private nonisolated static func writeScript() throws {
        let dir = scriptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try AgentHookScript.text.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    private nonisolated static func upsertClaude() throws {
        var root = try readJSONObjectOrEmpty(at: claudeSettingsURL)
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        for (event, matchers) in claudeEvents {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            groups = removeOurHooks(from: groups)
            for matcher in matchers {
                var group: [String: Any] = [
                    "hooks": [["type": "command", "command": claudeCommand]]
                ]
                if let matcher { group["matcher"] = matcher }
                groups.append(group)
            }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try writeJSONObject(root, to: claudeSettingsURL)
    }

    private nonisolated static func upsertCodex() throws {
        var root = try readJSONObjectOrEmpty(at: codexHooksURL)
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        for event in codexEvents {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            groups = removeOurHooks(from: groups)
            let group: [String: Any] = [
                "hooks": [["type": "command", "command": codexCommand, "timeout": 300]]
            ]
            groups.append(group)
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try writeJSONObject(root, to: codexHooksURL)
    }

    private nonisolated static func pruneOurEntries(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard var root = readJSONObject(at: url) else {
            throw InstallerError.unparseableConfig(url.path)
        }
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned = removeOurHooks(from: groups)
            if cleaned.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = cleaned
            }
        }
        root["hooks"] = hooks
        try writeJSONObject(root, to: url)
    }

    /// Remove our command entries from each matcher group; drop groups left empty.
    /// All non-Atoll entries are preserved byte-for-byte (same parsed values).
    private nonisolated static func removeOurHooks(from groups: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for var group in groups {
            if let inner = group["hooks"] as? [[String: Any]] {
                let kept = inner.filter { hook in
                    guard let cmd = hook["command"] as? String else { return true }
                    return !cmd.contains(AgentHookScript.marker)
                }
                if kept.isEmpty && inner.count != kept.count {
                    // Group existed only for our hooks — drop it entirely.
                    continue
                }
                group["hooks"] = kept
            }
            result.append(group)
        }
        return result
    }

    // MARK: - JSON round-trip

    private nonisolated static func readJSONObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Missing or empty file → `[:]`. Present-but-unreadable or unparseable →
    /// throw (never clobber a file we could not actually read).
    private nonisolated static func readJSONObjectOrEmpty(at url: URL) throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        } catch {
            throw InstallerError.unparseableConfig(url.path)
        }
        guard !data.isEmpty, data.contains(where: { !" \n\r\t".utf8.contains($0) }) else {
            return [:]
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InstallerError.unparseableConfig(url.path)
        }
        return obj
    }

    private nonisolated static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw InstallerError.writeFailed(url.path)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw InstallerError.writeFailed(url.path)
        }
    }
}
