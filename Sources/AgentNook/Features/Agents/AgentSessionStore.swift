import Foundation
import Combine

/// Single source of truth for live agent sessions. Owns the socket server and
/// the per-session transcript tailers; applies the hook status → state machine;
/// discovers pre-existing sessions from transcripts on launch; polls Codex
/// liveness; and drives notifications.
@MainActor
final class AgentSessionStore: ObservableObject {
    static let shared = AgentSessionStore()

    @Published private(set) var sessions: [String: AgentSession] = [:]
    /// True while the socket server is bound and listening.
    @Published private(set) var socketActive = false

    /// Sessions sorted: needs-attention first, then most recent activity.
    var orderedSessions: [AgentSession] {
        sessions.values.sorted { a, b in
            if a.state.needsAttention != b.state.needsAttention {
                return a.state.needsAttention
            }
            return a.lastActivity > b.lastActivity
        }
    }

    /// Any session needing the user's attention (input or permission).
    var attention: Bool {
        sessions.values.contains { $0.state.needsAttention }
    }

    var liveSessionCount: Int {
        sessions.values.filter { $0.state != .ended }.count
    }

    private let server = AgentSocketServer()
    private var tailers: [String: AgentTranscriptTailer] = [:]
    private var livenessTimer: Timer?
    private var staleTimer: Timer?
    private var livenessMisses: [String: Int] = [:]
    private var removalTasks: [String: Task<Void, Never>] = [:]
    private var started = false

    /// Sessions linger this long after `ended` before disappearing.
    private let endedLinger: TimeInterval = 60

    // MARK: - Lifecycle

    /// Idempotent. Call once at app launch (AppDelegate).
    func start() {
        guard !started else { return }
        started = true

        server.onEnvelope = { [weak self] envelope, replyKey in
            // Delivered on the main queue by the server.
            MainActor.assumeIsolated {
                self?.ingest(envelope, replyKey: replyKey)
            }
        }
        socketActive = server.start()

        discoverExisting()

        let liveness = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollCodexLiveness() }
        }
        liveness.tolerance = 0.5
        livenessTimer = liveness

        let stale = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepStaleSessions() }
        }
        stale.tolerance = 5
        staleTimer = stale
    }

    func stop() {
        guard started else { return }
        started = false
        server.stop()
        socketActive = false
        livenessTimer?.invalidate(); livenessTimer = nil
        staleTimer?.invalidate(); staleTimer = nil
        for (_, tailer) in tailers { tailer.stop() }
        tailers.removeAll()
        for (_, task) in removalTasks { task.cancel() }
        removalTasks.removeAll()
    }

    // MARK: - Envelope ingestion (hook → state machine)

    func ingest(_ envelope: AgentHookEnvelope, replyKey: String?) {
        let key = AgentSession.key(provider: envelope.provider, sessionId: envelope.sessionId)
        let isNew = sessions[key] == nil

        // Don't materialize sessions we only ever hear "ended" from.
        if isNew && envelope.status == "ended" { return }

        var session = sessions[key] ?? AgentSession(provider: envelope.provider, sessionId: envelope.sessionId)
        let previousState = session.state

        // Merge facts carried by every envelope.
        if let cwd = envelope.cwd, !cwd.isEmpty { session.cwd = cwd }
        if let path = envelope.transcriptPath, !path.isEmpty { session.transcriptPath = path }
        if let mode = envelope.permissionMode { session.permissionMode = mode }
        if let interactive = envelope.interactive { session.interactive = interactive }
        if let pid = envelope.processID { session.processID = pid }
        if let origin = envelope.codexOrigin { session.codexOrigin = origin }
        if let model = envelope.model, !model.isEmpty { session.model = model }
        if let prompt = envelope.userPrompt, !prompt.isEmpty { session.lastUserPrompt = prompt }
        if let message = envelope.lastAssistantMessage, !message.isEmpty {
            session.lastAssistantMessage = message
        }
        if session.transcriptPath == nil, envelope.provider == .claude, !session.cwd.isEmpty {
            session.transcriptPath = Self.claudeFallbackTranscriptPath(
                cwd: session.cwd, sessionId: envelope.sessionId)
        }

        var completedHint = false

        switch envelope.status {
        case "session_start":
            if isNew { session.state = .idle }

        case "processing":
            session.state = .working
            session.pendingPermission = nil
            if envelope.event == "PostToolUse", let toolUseId = envelope.toolUseId {
                session.finishToolEvent(id: toolUseId, success: true)
            }

        case "running_tool":
            session.state = .runningTool
            session.pendingPermission = nil
            let toolName = envelope.tool ?? "Tool"
            let id = envelope.toolUseId ?? UUID().uuidString
            let input = envelope.toolInputJSON
                .flatMap { $0.data(using: .utf8) }
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            session.appendToolEvent(AgentToolEvent(
                id: id, name: toolName,
                inputSummary: AgentToolEvent.summarize(tool: toolName, input: input),
                status: .running, timestamp: Date()))

        case "compacting":
            session.state = .compacting

        case "waiting_for_input":
            session.state = .waitingForInput
            session.pendingPermission = nil

        case "permission_request":
            session.state = .permissionRequest
            if let replyKey {
                session.pendingPermission = AgentPermissionRequestPayload(
                    key: replyKey,
                    event: envelope.event,
                    toolName: envelope.tool ?? "Tool",
                    toolUseId: envelope.toolUseId ?? "-",
                    toolInputJSON: envelope.toolInputJSON ?? "{}",
                    suggestionsJSON: envelope.permissionSuggestionsJSON,
                    receivedAt: Date())
            }

        case "ended":
            session.state = .ended
            session.endedAt = Date()
            session.pendingPermission = nil
            stopTailer(for: key)
            scheduleRemoval(of: key)

        case "notification":
            let type = envelope.notificationType ?? ""
            if type.contains("permission_prompt") {
                // The CLI is showing a permission prompt we could not intercept —
                // surface attention (no pendingPermission = UI offers "jump to terminal").
                if session.pendingPermission == nil { session.state = .permissionRequest }
            } else if type.contains("agent_needs_input") || type.contains("idle_prompt") {
                if session.state != .permissionRequest { session.state = .waitingForInput }
            } else if type.contains("agent_completed") {
                if session.state != .permissionRequest { session.state = .waitingForInput }
                completedHint = true
            }
            if session.lastAssistantMessage == nil, let msg = envelope.notificationMessage {
                session.lastAssistantMessage = msg
            }

        default:
            break
        }

        session.lastActivity = Date()
        session.isStale = false
        session.revision &+= 1
        if session.state != .ended {
            removalTasks.removeValue(forKey: key)?.cancel()
            session.endedAt = nil
        }
        sessions[key] = session

        ensureTailer(for: session)

        AgentNotifier.shared.sessionTransition(
            from: previousState, session: session, completedHint: completedHint)
    }

    // MARK: - Permission resolution

    /// Write a raw hook-decision JSON to the held connection for this session's
    /// pending permission, then mark the session working again.
    func resolvePermission(sessionKey: String, responseJSON: String) {
        guard var session = sessions[sessionKey],
              let pending = session.pendingPermission else { return }
        server.resolvePermission(key: pending.key, responseJSON: responseJSON)
        session.pendingPermission = nil
        session.state = .working
        session.lastActivity = Date()
        session.revision &+= 1
        sessions[sessionKey] = session
    }

    /// Convenience for the approval card: allow / allow-and-remember / deny.
    func respondToPermission(sessionKey: String, allow: Bool, remember: Bool = false,
                             denyMessage: String = "User denied this action from AgentNook.") {
        guard let session = sessions[sessionKey],
              let pending = session.pendingPermission else { return }
        let json: String
        if allow {
            json = AgentPermissionDecision.allowJSON(
                event: pending.event,
                updatedInput: pending.toolInput,
                rememberSuggestions: remember ? pending.suggestions : nil)
        } else {
            json = AgentPermissionDecision.denyJSON(event: pending.event, message: denyMessage)
        }
        resolvePermission(sessionKey: sessionKey, responseJSON: json)
    }

    /// Answer an AskUserQuestion permission request.
    func answerQuestion(sessionKey: String, question: String, answer: String) {
        guard let session = sessions[sessionKey],
              let pending = session.pendingPermission else { return }
        let json = AgentPermissionDecision.askUserQuestionAnswerJSON(
            event: pending.event,
            originalInput: pending.toolInput,
            question: question,
            answer: answer)
        resolvePermission(sessionKey: sessionKey, responseJSON: json)
    }

    // MARK: - Transcript tailers

    private func ensureTailer(for session: AgentSession) {
        let key = session.id
        guard session.state != .ended,
              let path = session.transcriptPath, !path.isEmpty,
              tailers[key] == nil
        else { return }
        let provider = session.provider
        let tailer = AgentTranscriptTailer(provider: provider, path: path) { [weak self] events, isHistorical in
            MainActor.assumeIsolated {
                self?.applyTranscriptEvents(events, to: key, historical: isHistorical)
            }
        }
        tailers[key] = tailer
        tailer.start()
    }

    private func stopTailer(for key: String) {
        tailers.removeValue(forKey: key)?.stop()
    }

    private func applyTranscriptEvents(_ events: [AgentTranscriptEvent], to key: String,
                                       historical: Bool = false) {
        guard var session = sessions[key] else { return }
        var changed = false
        for event in events {
            switch event {
            case .assistantMessage(let text):
                session.lastAssistantMessage = text
                changed = true
            case .usage(let tokens, let window):
                session.tokensUsed = tokens
                if let window { session.contextWindow = window }
                changed = true
            case .model(let model):
                if session.model != model { session.model = model; changed = true }
            case .interrupted:
                // Stale interrupts from the initial catch-up parse must not
                // flip a session the hooks just told us is busy.
                guard !historical else { break }
                if session.state.isBusy || session.state == .permissionRequest {
                    session.state = .idle
                    session.pendingPermission = nil
                    changed = true
                }
            case .toolStarted(let toolEvent):
                session.appendToolEvent(toolEvent)
                changed = true
            case .toolFinished(let id, let success):
                session.finishToolEvent(id: id, success: success)
                changed = true
            case .userPrompt(let prompt):
                session.lastUserPrompt = prompt
                changed = true
            }
        }
        guard changed else { return }
        if !historical {
            session.lastActivity = Date()
            session.isStale = false
        }
        session.revision &+= 1
        sessions[key] = session
    }

    // MARK: - Discovery of pre-existing sessions

    /// Scan recent Claude / Codex transcripts so sessions started before
    /// AgentNook launched still show up (state is a best guess, no PID).
    func discoverExisting() {
        let cutoffMinutes = SettingsStore.shared.agentsIdleCutoffMinutes
        let existingKeys = Set(sessions.keys)
        Task.detached(priority: .utility) {
            let discovered = AgentSessionDiscovery.discover(
                cutoff: Date().addingTimeInterval(-cutoffMinutes * 60))
            await MainActor.run {
                let store = AgentSessionStore.shared
                for var session in discovered {
                    let key = session.id
                    // Hook-fed sessions always win over discovery.
                    guard !existingKeys.contains(key), store.sessions[key] == nil else { continue }
                    session.revision = 1
                    store.sessions[key] = session
                    store.ensureTailer(for: session)
                }
            }
        }
    }

    // MARK: - Codex liveness

    private func pollCodexLiveness() {
        for (key, session) in sessions {
            guard session.provider == .codex,
                  session.state != .ended,
                  let pid = session.processID
            else { continue }
            let alive = kill(pid, 0) == 0 || errno == EPERM
            if alive {
                livenessMisses[key] = 0
            } else {
                let misses = (livenessMisses[key] ?? 0) + 1
                livenessMisses[key] = misses
                if misses >= 2 {
                    livenessMisses.removeValue(forKey: key)
                    var ended = session
                    let previous = ended.state
                    ended.state = .ended
                    ended.endedAt = Date()
                    ended.pendingPermission = nil
                    ended.revision &+= 1
                    sessions[key] = ended
                    stopTailer(for: key)
                    scheduleRemoval(of: key)
                    AgentNotifier.shared.sessionTransition(from: previous, session: ended)
                }
            }
        }
    }

    // MARK: - Stale sweep & removal

    private func sweepStaleSessions() {
        let cutoff = SettingsStore.shared.agentsIdleCutoffMinutes * 60
        guard cutoff > 0 else { return }
        let now = Date()
        for (key, session) in sessions {
            guard session.state != .ended else { continue }
            let idle = now.timeIntervalSince(session.lastActivity)
            if idle > cutoff * 2 {
                // Long-dead: drop silently.
                stopTailer(for: key)
                sessions.removeValue(forKey: key)
            } else if idle > cutoff, !session.isStale {
                var stale = session
                stale.isStale = true
                if stale.state.isBusy { stale.state = .idle }
                stale.revision &+= 1
                sessions[key] = stale
            }
        }
    }

    private func scheduleRemoval(of key: String) {
        removalTasks[key]?.cancel()
        removalTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(60 * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if self.sessions[key]?.state == .ended {
                self.sessions.removeValue(forKey: key)
            }
            self.removalTasks.removeValue(forKey: key)
        }
    }

    // MARK: - Helpers

    /// `~/.claude/projects/<cwd with '/' and '.' → '-'>/<session_id>.jsonl`
    nonisolated static func claudeFallbackTranscriptPath(cwd: String, sessionId: String) -> String {
        let projectDir = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map {
            ($0 as NSString).expandingTildeInPath
        } ?? (NSHomeDirectory() + "/.claude")
        return "\(base)/projects/\(projectDir)/\(sessionId).jsonl"
    }
}

// MARK: - Discovery (off-main worker)

/// Scans on-disk transcripts for recently-active sessions. Pure functions,
/// runs on a background task.
enum AgentSessionDiscovery {

    static func discover(cutoff: Date) -> [AgentSession] {
        var result: [AgentSession] = []
        result.append(contentsOf: discoverClaude(cutoff: cutoff))
        result.append(contentsOf: discoverCodex(cutoff: cutoff))
        return result
    }

    // MARK: Claude — ~/.claude/projects/*/*.jsonl

    private static func discoverClaude(cutoff: Date) -> [AgentSession] {
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map {
            ($0 as NSString).expandingTildeInPath
        } ?? (NSHomeDirectory() + "/.claude")
        let projectsDir = base + "/projects"
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }

        var sessions: [AgentSession] = []
        for project in projects {
            let dir = projectsDir + "/" + project
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = dir + "/" + file
                guard let mtime = fileModificationDate(path), mtime > cutoff else { continue }
                let sessionId = String(file.dropLast(".jsonl".count))
                guard !sessionId.isEmpty else { continue }
                if let session = buildClaudeSession(sessionId: sessionId, path: path, mtime: mtime) {
                    sessions.append(session)
                }
            }
        }
        return sessions
    }

    private static func buildClaudeSession(sessionId: String, path: String, mtime: Date) -> AgentSession? {
        let lines = tailLines(path: path, maxLines: 50)
        guard !lines.isEmpty else { return nil }

        var session = AgentSession(provider: .claude, sessionId: sessionId)
        session.transcriptPath = path
        session.lastActivity = mtime
        session.interactive = nil

        let parser = AgentTranscriptParser(provider: .claude)
        var lastType: String?
        for line in lines {
            if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                if let cwd = obj["cwd"] as? String, !cwd.isEmpty { session.cwd = cwd }
                if let type = obj["type"] as? String, type == "assistant" || type == "user" {
                    if obj["isMeta"] as? Bool != true { lastType = type }
                }
            }
            for event in parser.parse(line: line) {
                apply(event, to: &session)
            }
        }
        guard !session.cwd.isEmpty else { return nil }

        // State guess: an assistant turn at the tail of a recently-touched file
        // usually means "finished, waiting for the user".
        if lastType == "assistant", Date().timeIntervalSince(mtime) < 600 {
            session.state = .waitingForInput
        } else {
            session.state = .idle
        }
        return session
    }

    // MARK: Codex — ~/.codex/sessions/**/*.jsonl (rollout files)

    private static func discoverCodex(cutoff: Date) -> [AgentSession] {
        let base = NSHomeDirectory() + "/.codex/sessions"
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: base) else { return [] }

        var sessions: [AgentSession] = []
        while let rel = enumerator.nextObject() as? String {
            guard rel.hasSuffix(".jsonl") else { continue }
            let path = base + "/" + rel
            guard let mtime = fileModificationDate(path), mtime > cutoff else { continue }
            let fileName = (rel as NSString).lastPathComponent
            guard let sessionId = codexSessionId(fromRolloutFileName: fileName) else { continue }
            if let session = buildCodexSession(sessionId: sessionId, path: path, mtime: mtime) {
                sessions.append(session)
            }
        }
        return sessions
    }

    private static func buildCodexSession(sessionId: String, path: String, mtime: Date) -> AgentSession? {
        var session = AgentSession(provider: .codex, sessionId: sessionId)
        session.transcriptPath = path
        session.lastActivity = mtime
        session.interactive = nil

        // Head: session_meta / turn_context carry cwd + model.
        for line in headLines(path: path, maxLines: 8) {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            let payload = (obj["payload"] as? [String: Any]) ?? obj
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { session.cwd = cwd }
            if let model = payload["model"] as? String, !model.isEmpty { session.model = model }
        }

        let parser = AgentTranscriptParser(provider: .codex)
        var lastWasAssistant = false
        for line in tailLines(path: path, maxLines: 50) {
            if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                let payload = (obj["payload"] as? [String: Any]) ?? obj
                if let cwd = payload["cwd"] as? String, !cwd.isEmpty { session.cwd = cwd }
            }
            let events = parser.parse(line: line)
            for event in events {
                apply(event, to: &session)
                if case .assistantMessage = event { lastWasAssistant = true }
                if case .userPrompt = event { lastWasAssistant = false }
                if case .toolStarted = event { lastWasAssistant = false }
            }
        }
        guard !session.cwd.isEmpty else { return nil }

        if lastWasAssistant, Date().timeIntervalSince(mtime) < 600 {
            session.state = .waitingForInput
        } else {
            session.state = .idle
        }
        return session
    }

    /// rollout-2025-07-18T10-42-58-<uuid>.jsonl → uuid (last 5 dash components).
    static func codexSessionId(fromRolloutFileName fileName: String) -> String? {
        let stem = fileName.hasSuffix(".jsonl") ? String(fileName.dropLast(".jsonl".count)) : fileName
        let parts = stem.split(separator: "-")
        guard parts.count >= 5 else { return nil }
        let uuid = parts.suffix(5).joined(separator: "-")
        return UUID(uuidString: uuid) != nil ? uuid : nil
    }

    // MARK: shared helpers

    private static func apply(_ event: AgentTranscriptEvent, to session: inout AgentSession) {
        switch event {
        case .assistantMessage(let text): session.lastAssistantMessage = text
        case .usage(let tokens, let window):
            session.tokensUsed = tokens
            if let window { session.contextWindow = window }
        case .model(let model): session.model = model
        case .interrupted: session.state = .idle
        case .toolStarted(let toolEvent): session.appendToolEvent(toolEvent)
        case .toolFinished(let id, let success): session.finishToolEvent(id: id, success: success)
        case .userPrompt(let prompt): session.lastUserPrompt = prompt
        }
    }

    private static func fileModificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Last `maxLines` newline-separated chunks of a file, reading at most 256 KB.
    private static func tailLines(path: String, maxLines: Int) -> [Data] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        let start = size > window ? size - window : 0
        do { try handle.seek(toOffset: start) } catch { return [] }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        let newline: UInt8 = 0x0A
        var lines: [Data] = data.split(separator: newline, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty {
            lines.removeFirst() // first chunk is probably a partial line
        }
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        return lines
    }

    private static func headLines(path: String, maxLines: Int) -> [Data] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty else { return [] }
        let newline: UInt8 = 0x0A
        let lines: [Data] = data.split(separator: newline, omittingEmptySubsequences: true)
        return Array(lines.prefix(maxLines))
    }
}
