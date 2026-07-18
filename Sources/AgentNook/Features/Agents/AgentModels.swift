import Foundation

// MARK: - Provider

/// Which coding agent produced a session.
enum AgentProvider: String, Codable, CaseIterable, Hashable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

/// How a Codex session was launched (affects jump-to-session behavior).
enum AgentCodexOrigin: String, Codable {
    case cli
    case desktop
}

// MARK: - Session state

enum AgentSessionState: String, Codable {
    case idle
    case working
    case runningTool
    case waitingForInput
    case permissionRequest
    case compacting
    case ended

    /// True when the user should look at this session.
    var needsAttention: Bool {
        self == .waitingForInput || self == .permissionRequest
    }

    /// True while the agent is actively doing something.
    var isBusy: Bool {
        self == .working || self == .runningTool || self == .compacting
    }
}

// MARK: - Tool events

struct AgentToolEvent: Identifiable, Equatable {
    enum Status: String {
        case running
        case success
        case error
    }

    /// Stable id: the tool_use_id / call_id when known, otherwise a UUID.
    let id: String
    var name: String
    var inputSummary: String
    var status: Status
    var timestamp: Date

    /// Produce a short, single-line human summary of a tool input dictionary.
    static func summarize(tool: String, input: [String: Any]?) -> String {
        guard let input else { return "" }
        let preferredKeys: [String]
        switch tool {
        case "Bash": preferredKeys = ["command", "cmd", "description"]
        case "Edit", "Write", "Read", "NotebookEdit": preferredKeys = ["file_path", "path", "notebook_path"]
        case "Glob", "Grep": preferredKeys = ["pattern", "query"]
        case "WebFetch", "WebSearch": preferredKeys = ["url", "query"]
        case "Task": preferredKeys = ["description", "prompt"]
        case "AskUserQuestion": preferredKeys = ["question", "questions"]
        default: preferredKeys = ["command", "cmd", "file_path", "path", "url", "query", "pattern", "description", "prompt"]
        }
        for key in preferredKeys {
            if let value = input[key] as? String, !value.isEmpty {
                return AgentToolEvent.clip(value)
            }
        }
        // Fall back to the first string value, then to compact JSON.
        for (_, value) in input {
            if let s = value as? String, !s.isEmpty { return AgentToolEvent.clip(s) }
        }
        if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return AgentToolEvent.clip(s)
        }
        return ""
    }

    private static func clip(_ s: String, limit: Int = 160) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ⏎ ")
        if flat.count <= limit { return flat }
        return String(flat.prefix(limit)) + "…"
    }
}

// MARK: - Pending permission

/// A permission request from a hook that is being held open on the socket,
/// waiting for the user's decision in the notch.
struct AgentPermissionRequestPayload: Identifiable, Equatable {
    /// Reply-broker key: `provider:sessionId:event:toolUseId`. Also the id.
    let key: String
    /// The originating hook event name ("PermissionRequest").
    let event: String
    let toolName: String
    let toolUseId: String
    /// Raw JSON string of the `tool_input` object.
    let toolInputJSON: String
    /// Raw JSON string of the `permission_suggestions` array, if any.
    let suggestionsJSON: String?
    let receivedAt: Date

    var id: String { key }

    /// Decoded tool input (best effort).
    var toolInput: [String: Any]? {
        guard let data = toolInputJSON.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Decoded permission suggestions (`[{behavior, description?, rule?, destination?}, …]`).
    var suggestions: [[String: Any]] {
        guard let json = suggestionsJSON, let data = json.data(using: .utf8) else { return [] }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
    }

    /// One-line summary of the tool input for compact UI.
    var inputSummary: String {
        AgentToolEvent.summarize(tool: toolName, input: toolInput)
    }
}

// MARK: - Session

struct AgentSession: Identifiable, Equatable {
    static func == (lhs: AgentSession, rhs: AgentSession) -> Bool { lhs.id == rhs.id && lhs.revision == rhs.revision }

    let provider: AgentProvider
    let sessionId: String

    var cwd: String = ""
    var model: String?
    /// Claude permission mode: default / plan / acceptEdits / auto / dontAsk / bypassPermissions.
    var permissionMode: String?
    /// nil = unknown (e.g. discovered from transcripts, no hook seen yet).
    var interactive: Bool?
    /// PID of the `claude` / `codex` process, when the hook could find it.
    var processID: pid_t?
    var transcriptPath: String?

    var state: AgentSessionState = .idle
    var lastActivity: Date = Date()
    /// Set once the session went beyond `agentsIdleCutoffMinutes` without activity.
    var isStale: Bool = false
    var endedAt: Date?

    var lastUserPrompt: String?
    var lastAssistantMessage: String?

    /// Ring buffer of the most recent tool events (max 20, oldest first).
    var toolEvents: [AgentToolEvent] = []

    /// Set while a hook connection is held open awaiting an approve/deny decision.
    var pendingPermission: AgentPermissionRequestPayload?

    var tokensUsed: Int?
    var contextWindow: Int?

    var codexOrigin: AgentCodexOrigin?

    /// Bumped on every mutation so SwiftUI diffing stays cheap.
    var revision: Int = 0

    var id: String { AgentSession.key(provider: provider, sessionId: sessionId) }

    var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? provider.displayName : name
    }

    /// 0…1 context fill when both numbers are known.
    var contextFraction: Double? {
        guard let used = tokensUsed, let window = contextWindow, window > 0 else { return nil }
        return min(1.0, Double(used) / Double(window))
    }

    static func key(provider: AgentProvider, sessionId: String) -> String {
        "\(provider.rawValue):\(sessionId)"
    }

    mutating func appendToolEvent(_ event: AgentToolEvent) {
        if let idx = toolEvents.firstIndex(where: { $0.id == event.id }) {
            toolEvents[idx] = event
        } else {
            toolEvents.append(event)
            if toolEvents.count > 20 { toolEvents.removeFirst(toolEvents.count - 20) }
        }
    }

    mutating func finishToolEvent(id: String, success: Bool) {
        guard let idx = toolEvents.firstIndex(where: { $0.id == id }) else { return }
        if toolEvents[idx].status == .running {
            toolEvents[idx].status = success ? .success : .error
        }
    }
}

// MARK: - Hook envelope (socket payload)

/// One decoded JSON line received from the hook script over /tmp/agentnook.sock.
struct AgentHookEnvelope {
    let provider: AgentProvider
    let sessionId: String
    let event: String
    let status: String

    let transcriptPath: String?
    let cwd: String?
    let interactive: Bool?
    let permissionMode: String?
    let userPrompt: String?
    let tool: String?
    let toolUseId: String?
    /// Raw JSON string of tool_input (re-serialized).
    let toolInputJSON: String?
    /// Raw JSON string of permission_suggestions (re-serialized).
    let permissionSuggestionsJSON: String?
    let processID: pid_t?
    let codexOrigin: AgentCodexOrigin?
    let model: String?
    let lastAssistantMessage: String?
    /// Notification hook matcher / notification_type passthrough
    /// (agent_needs_input, agent_completed, permission_prompt, idle_prompt, …).
    let notificationType: String?
    let notificationMessage: String?

    init?(json: [String: Any]) {
        guard
            let providerRaw = json["provider"] as? String,
            let provider = AgentProvider(rawValue: providerRaw),
            let sessionId = json["session_id"] as? String, !sessionId.isEmpty,
            let event = json["event"] as? String
        else { return nil }

        self.provider = provider
        self.sessionId = sessionId
        self.event = event
        self.status = (json["status"] as? String) ?? "processing"
        self.transcriptPath = json["transcript_path"] as? String
        self.cwd = json["cwd"] as? String
        self.interactive = json["interactive"] as? Bool
        self.permissionMode = json["permission_mode"] as? String
        self.userPrompt = json["user_prompt"] as? String
        self.tool = json["tool"] as? String
        self.toolUseId = json["tool_use_id"] as? String
        self.toolInputJSON = AgentHookEnvelope.reserialize(json["tool_input"])
        self.permissionSuggestionsJSON = AgentHookEnvelope.reserialize(json["permission_suggestions"])
        if let pid = json["claude_process_id"] as? Int ?? json["codex_process_id"] as? Int {
            self.processID = pid_t(pid)
        } else {
            self.processID = nil
        }
        self.codexOrigin = (json["codex_origin"] as? String).flatMap(AgentCodexOrigin.init(rawValue:))
        self.model = json["model"] as? String
        self.lastAssistantMessage = json["last_assistant_message"] as? String
        self.notificationType = json["notification_type"] as? String
        self.notificationMessage = json["message"] as? String
    }

    init?(jsonLine data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        self.init(json: obj)
    }

    /// Key used to pair a held-open PermissionRequest connection with its decision.
    var permissionReplyKey: String {
        "\(provider.rawValue):\(sessionId):\(event):\(toolUseId ?? "-")"
    }

    private static func reserialize(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let s = value as? String { return s }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Hook decision JSON builders

/// Builders for the JSON a hook prints to stdout to resolve a permission request.
/// Shapes per the official Claude Code hooks docs (Codex mirrors them).
enum AgentPermissionDecision {

    /// Allow. `updatedInput` (when non-nil) rewrites the tool arguments.
    /// `rememberSuggestions` should be the decoded `permission_suggestions` array
    /// when the user picked "Allow and don't ask again" — the first `allow` entry
    /// (preferring destination == localSettings) is passed through verbatim.
    static func allowJSON(event: String,
                          updatedInput: [String: Any]? = nil,
                          rememberSuggestions: [[String: Any]]? = nil) -> String {
        var decision: [String: Any] = ["behavior": "allow"]
        decision["updatedInput"] = updatedInput ?? [:]
        if let suggestions = rememberSuggestions, !suggestions.isEmpty {
            let allows = suggestions.filter { ($0["behavior"] as? String) == "allow" }
            let preferred = allows.first { ($0["destination"] as? String) == "localSettings" } ?? allows.first
            if let preferred { decision["updatedPermissions"] = [preferred] }
        }
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": event,
                "decision": decision,
            ]
        ]
        return AgentPermissionDecision.encode(output)
    }

    /// Deny with a message shown to the model.
    static func denyJSON(event: String, message: String = "User denied this action from AgentNook.") -> String {
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": event,
                "decision": [
                    "behavior": "deny",
                    "message": message,
                ],
            ]
        ]
        return AgentPermissionDecision.encode(output)
    }

    /// Answer an AskUserQuestion tool call: allow with the answers injected into the input.
    static func askUserQuestionAnswerJSON(event: String,
                                          originalInput: [String: Any]?,
                                          question: String,
                                          answer: String) -> String {
        var input = originalInput ?? [:]
        var answers = (input["answers"] as? [String: Any]) ?? [:]
        answers[question] = answer
        input["answers"] = answers
        return allowJSON(event: event, updatedInput: input)
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return #"{"hookSpecificOutput":{}}"#
        }
        return String(data: data, encoding: .utf8) ?? #"{"hookSpecificOutput":{}}"#
    }
}
