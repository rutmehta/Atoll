import Foundation

// MARK: - Transcript events

/// Facts extracted from a transcript, provider-agnostic.
enum AgentTranscriptEvent {
    case assistantMessage(String)
    case usage(tokensUsed: Int, contextWindow: Int?)
    case model(String)
    case interrupted
    case toolStarted(AgentToolEvent)
    case toolFinished(id: String, success: Bool)
    case userPrompt(String)
}

// MARK: - Parser

/// Stateful line parser for Claude JSONL and Codex rollout transcripts.
/// Keeps a dedupe set for Codex call_ids so offset resets don't duplicate events.
final class AgentTranscriptParser {
    let provider: AgentProvider
    private var seenCallIds: Set<String> = []

    init(provider: AgentProvider) {
        self.provider = provider
    }

    func parse(line: Data) -> [AgentTranscriptEvent] {
        guard !line.isEmpty else { return [] }
        switch provider {
        case .claude: return parseClaudeLine(line)
        case .codex: return parseCodexLine(line)
        }
    }

    // MARK: Claude JSONL

    private func parseClaudeLine(_ data: Data) -> [AgentTranscriptEvent] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String
        else { return [] }

        var events: [AgentTranscriptEvent] = []
        switch type {
        case "assistant":
            if obj["isMeta"] as? Bool == true { return [] }
            guard let message = obj["message"] as? [String: Any] else { return [] }
            let model = message["model"] as? String
            if model == "<synthetic>" { return [] }
            if let model, !model.isEmpty { events.append(.model(model)) }

            var text = ""
            if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks where (block["type"] as? String) == "text" {
                    if let t = block["text"] as? String, !t.isEmpty {
                        if !text.isEmpty { text += "\n" }
                        text += t
                    }
                }
            } else if let s = message["content"] as? String {
                text = s
            }
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                events.append(.assistantMessage(trimmedText))
            }
            if let usage = message["usage"] as? [String: Any] {
                let input = Self.intValue(usage["input_tokens"])
                let cacheCreate = Self.intValue(usage["cache_creation_input_tokens"])
                let cacheRead = Self.intValue(usage["cache_read_input_tokens"])
                let output = Self.intValue(usage["output_tokens"])
                let total = input + cacheCreate + cacheRead + output
                if total > 0 {
                    events.append(.usage(tokensUsed: total, contextWindow: nil))
                }
            }

        case "user":
            // Tool results echoed back as user messages are not real prompts.
            if obj["toolUseResult"] != nil { return [] }
            if obj["isMeta"] as? Bool == true { return [] }
            // Esc-interrupt detection: produces no hook event, only this line.
            if let raw = String(data: data, encoding: .utf8),
               raw.contains("[Request interrupted by user") {
                return [.interrupted]
            }
            if let message = obj["message"] as? [String: Any] {
                var text = ""
                if let s = message["content"] as? String {
                    text = s
                } else if let blocks = message["content"] as? [[String: Any]] {
                    for block in blocks where (block["type"] as? String) == "text" {
                        if let t = block["text"] as? String, !t.isEmpty {
                            if !text.isEmpty { text += "\n" }
                            text += t
                        }
                    }
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !trimmed.hasPrefix("<") {
                    events.append(.userPrompt(trimmed))
                }
            }

        default:
            break
        }
        return events
    }

    // MARK: Codex rollout JSONL

    private func parseCodexLine(_ data: Data) -> [AgentTranscriptEvent] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String
        else { return [] }
        let payload = (obj["payload"] as? [String: Any]) ?? obj

        switch type {
        case "response_item":
            return parseCodexResponseItem(payload)
        case "event_msg":
            return parseCodexEventMsg(payload)
        case "turn_context", "session_meta":
            var events: [AgentTranscriptEvent] = []
            if let model = payload["model"] as? String, !model.isEmpty {
                events.append(.model(model))
            }
            return events
        default:
            return []
        }
    }

    private func parseCodexResponseItem(_ payload: [String: Any]) -> [AgentTranscriptEvent] {
        guard let itemType = payload["type"] as? String else { return [] }
        switch itemType {
        case "message":
            guard (payload["role"] as? String) == "assistant" else { return [] }
            var text = ""
            if let blocks = payload["content"] as? [[String: Any]] {
                for block in blocks where (block["type"] as? String) == "output_text" {
                    if let t = block["text"] as? String, !t.isEmpty {
                        if !text.isEmpty { text += "\n" }
                        text += t
                    }
                }
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.assistantMessage(trimmed)]

        case "function_call":
            guard let callId = (payload["call_id"] as? String) ?? (payload["id"] as? String) else { return [] }
            guard seenCallIds.insert(callId).inserted else { return [] }
            let rawName = (payload["name"] as? String) ?? "tool"
            let isShell = ["exec_command", "shell", "shell_command", "local_shell", "container.exec"].contains(rawName)
            let name = isShell ? "Bash" : rawName
            var summary = ""
            if let argsString = payload["arguments"] as? String,
               let argsData = argsString.data(using: .utf8),
               let args = (try? JSONSerialization.jsonObject(with: argsData)) as? [String: Any] {
                summary = AgentToolEvent.summarize(tool: name, input: args)
            }
            let event = AgentToolEvent(id: Self.codexEventId(callId), name: name,
                                       inputSummary: summary, status: .running, timestamp: Date())
            return [.toolStarted(event)]

        case "local_shell_call":
            guard let callId = (payload["call_id"] as? String) ?? (payload["id"] as? String) else { return [] }
            guard seenCallIds.insert(callId).inserted else { return [] }
            var summary = ""
            if let action = payload["action"] as? [String: Any] {
                if let cmd = action["command"] as? [String] {
                    summary = cmd.joined(separator: " ")
                } else if let cmd = action["command"] as? String {
                    summary = cmd
                }
            }
            let event = AgentToolEvent(id: Self.codexEventId(callId), name: "Bash",
                                       inputSummary: summary, status: .running, timestamp: Date())
            return [.toolStarted(event)]

        case "function_call_output":
            guard let callId = payload["call_id"] as? String else { return [] }
            let output = (payload["output"] as? String) ?? ""
            return [.toolFinished(id: Self.codexEventId(callId), success: Self.codexOutputSucceeded(output))]

        default:
            return []
        }
    }

    private func parseCodexEventMsg(_ payload: [String: Any]) -> [AgentTranscriptEvent] {
        guard let msgType = payload["type"] as? String else { return [] }
        switch msgType {
        case "turn_aborted":
            return [.interrupted]
        case "token_count":
            let info = (payload["info"] as? [String: Any]) ?? payload
            var used: Int?
            if let totalUsage = info["total_token_usage"] as? [String: Any] {
                let total = Self.intValue(totalUsage["total_tokens"])
                if total > 0 { used = total }
            }
            if used == nil {
                let flat = Self.intValue(info["total_tokens"])
                if flat > 0 { used = flat }
            }
            var window: Int?
            let w = Self.intValue(info["model_context_window"])
            if w > 0 { window = w }
            if let used {
                return [.usage(tokensUsed: used, contextWindow: window)]
            }
            return []
        case "agent_message":
            if let text = payload["message"] as? String,
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return [.assistantMessage(text)]
            }
            return []
        case "user_message":
            if let text = payload["message"] as? String,
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return [.userPrompt(text)]
            }
            return []
        default:
            return []
        }
    }

    /// Stable synthetic tool-event id for a Codex call_id.
    static func codexEventId(_ callId: String) -> String { "codex:\(callId)" }

    private static func codexOutputSucceeded(_ output: String) -> Bool {
        // The output string itself may be JSON {"output": "...", "metadata": {"exit_code": N}}.
        if let data = output.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let metadata = obj["metadata"] as? [String: Any] {
                let code = intValue(metadata["exit_code"])
                return code == 0
            }
            if let inner = obj["output"] as? String {
                return exitCodeFromText(inner) ?? true
            }
        }
        return exitCodeFromText(output) ?? true
    }

    private static func exitCodeFromText(_ text: String) -> Bool? {
        // Current Codex format: "Exit code: N" (anchored at output start);
        // legacy format: "... exited with code N".
        for pattern in [#"^Exit code: (\d+)"#, #"exited with code (\d+)"#] {
            if let range = text.range(of: pattern, options: .regularExpression) {
                let digits = text[range].drop { !$0.isNumber }
                return Int(digits) == 0
            }
        }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) ?? 0 }
        return 0
    }
}

// MARK: - Tailer

/// Watches one transcript file with a DispatchSource ([.write, .extend]),
/// debounces 100 ms, and incrementally parses new lines from a stored byte
/// offset (resetting if the file shrank). Events are delivered on the main queue.
final class AgentTranscriptTailer {

    let provider: AgentProvider
    let path: String

    /// Called on the main queue with each batch of parsed events, in file order.
    /// `isHistorical` is true for the initial catch-up parse of pre-existing
    /// content — consumers should ignore state-flipping events (interrupts) then.
    private let onEvents: (_ events: [AgentTranscriptEvent], _ isHistorical: Bool) -> Void

    private let queue = DispatchQueue(label: "com.atoll.agents.tailer", qos: .utility)
    private let parser: AgentTranscriptParser

    private var watchFD: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var retryTimer: DispatchSourceTimer?
    private var debounceWork: DispatchWorkItem?

    private var offset: UInt64 = 0
    private var partial = Data()
    private var stopped = false
    private var didInitialParse = false

    /// How much history to parse when first attaching (keeps huge files cheap).
    private let initialTailBytes: UInt64 = 256 * 1024

    init(provider: AgentProvider, path: String,
         onEvents: @escaping (_ events: [AgentTranscriptEvent], _ isHistorical: Bool) -> Void) {
        self.provider = provider
        self.path = path
        self.onEvents = onEvents
        self.parser = AgentTranscriptParser(provider: provider)
    }

    deinit {
        let src = source
        let timer = retryTimer
        queue.async {
            // fd ownership belongs to the source's cancel handler; closing it
            // here as well would double-close a possibly-recycled descriptor.
            src?.cancel()
            timer?.cancel()
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.attachOrRetry()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.debounceWork?.cancel()
            self.retryTimer?.cancel()
            self.retryTimer = nil
            self.source?.cancel()
            self.source = nil
        }
    }

    // MARK: Attach

    private func attachOrRetry() {
        guard source == nil, !stopped else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // Transcript may not exist yet (hook fired before the first write) —
            // poll every 2s until it appears.
            if retryTimer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 2, repeating: 2)
                timer.setEventHandler { [weak self] in self?.attachOrRetry() }
                timer.resume()
                retryTimer = timer
            }
            return
        }
        retryTimer?.cancel()
        retryTimer = nil
        watchFD = fd

        // Start from near the end so attaching to a long-lived transcript is cheap.
        let size = currentFileSize()
        if size > initialTailBytes {
            offset = size - initialTailBytes
            skipToNextNewline()
        } else {
            offset = 0
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: queue)
        src.setEventHandler { [weak self] in self?.scheduleParse() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src

        parseIncremental()
    }

    private func scheduleParse() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.parseIncremental() }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    // MARK: Parse

    private func parseIncremental() {
        guard !stopped else { return }
        let isHistorical = !didInitialParse
        didInitialParse = true
        let size = currentFileSize()
        if size < offset {
            // File shrank (rewritten) — start over. Parser dedupe survives.
            offset = 0
            partial.removeAll()
        }
        guard size > offset else { return }
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
        } catch { return }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)

        partial.append(data)
        var events: [AgentTranscriptEvent] = []
        while let newline = partial.firstIndex(of: 0x0A) {
            let line = partial.prefix(upTo: newline)
            partial.removeSubrange(...newline)
            events.append(contentsOf: parser.parse(line: Data(line)))
        }
        guard !events.isEmpty else { return }
        let callback = onEvents
        DispatchQueue.main.async { callback(events, isHistorical) }
    }

    private func skipToNextNewline() {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch { return }
        guard let data = try? handle.read(upToCount: 128 * 1024) else { return }
        if let newline = data.firstIndex(of: 0x0A) {
            offset += UInt64(newline + 1)
        }
    }

    private func currentFileSize() -> UInt64 {
        var st = stat()
        guard stat(path, &st) == 0 else { return 0 }
        return UInt64(max(0, st.st_size))
    }
}
