import Foundation
import Combine

// MARK: - Model

/// One quota window (5-hour, weekly, model-scoped weekly, …).
struct AgentUsageWindow: Identifiable, Equatable {
    let id: String
    let label: String
    /// 0…100
    let percent: Double
    let resetsAt: Date?
}

struct AgentProviderUsage: Equatable {
    var windows: [AgentUsageWindow]
    /// Codex credits balance (1 credit ≈ $0.04), when reported.
    var creditsBalance: Double?
    var fetchedAt: Date
}

enum AgentUsageStatus: Equatable {
    case idle
    case loading
    case loaded
    /// Data is present but the last refresh failed (or data is old) — dim it.
    case stale(String)
    /// No data at all; message + recovery hint for the UI.
    case error(String, recovery: String)

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }
}

// MARK: - Manager

/// Fetches Claude Code OAuth usage (keychain token → api.anthropic.com/api/oauth/usage)
/// and Codex usage (~/.codex/auth.json JWT → chatgpt.com/backend-api/wham/usage).
/// Refreshes on demand plus every 300 s while the panel is visible, with
/// exponential backoff on 401/429. Never prompts and never crashes when
/// credentials are missing — the UI shows a recovery hint instead.
@MainActor
final class AgentUsageManager: ObservableObject {
    static let shared = AgentUsageManager()

    @Published private(set) var claudeUsage: AgentProviderUsage?
    @Published private(set) var claudeStatus: AgentUsageStatus = .idle
    @Published private(set) var codexUsage: AgentProviderUsage?
    @Published private(set) var codexStatus: AgentUsageStatus = .idle

    /// Account labels for the settings view, derived from token presence.
    @Published private(set) var claudeAccountLabel: String?
    @Published private(set) var codexAccountLabel: String?

    private var refreshTimer: Timer?
    private var panelVisible = false
    private var inFlight: Set<AgentProvider> = []
    private var backoffUntil: [AgentProvider: Date] = [:]
    private var backoffInterval: [AgentProvider: TimeInterval] = [:]

    private let refreshInterval: TimeInterval = 300
    /// Data older than this is presented as stale even without a failed refresh.
    private let staleAfter: TimeInterval = 1200
    private let baseBackoff: TimeInterval = 60
    private let maxBackoff: TimeInterval = 3600

    // MARK: Public API

    /// Start/stop the 300 s refresh timer with panel visibility.
    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard visible else { return }
        refreshIfNeeded()
        let timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in
            MainActor.assumeIsolated { AgentUsageManager.shared.refresh() }
        }
        timer.tolerance = 30
        refreshTimer = timer
    }

    /// Refresh both providers (respects backoff unless `force`).
    func refresh(force: Bool = false) {
        refreshProvider(.claude, force: force)
        refreshProvider(.codex, force: force)
    }

    func refreshIfNeeded() {
        let now = Date()
        let claudeOld = claudeUsage.map { now.timeIntervalSince($0.fetchedAt) > 60 } ?? true
        let codexOld = codexUsage.map { now.timeIntervalSince($0.fetchedAt) > 60 } ?? true
        if claudeOld { refreshProvider(.claude, force: false) }
        if codexOld { refreshProvider(.codex, force: false) }
    }

    /// Retry button in the UI: clears backoff and refetches one provider.
    func retry(_ provider: AgentProvider) {
        backoffUntil[provider] = nil
        backoffInterval[provider] = nil
        refreshProvider(provider, force: true)
    }

    /// Probe token presence for the settings view (no network).
    func probeAccounts() {
        Task.detached(priority: .utility) {
            let claude = AgentUsageManager.readClaudeCredentials()
            let codex = AgentUsageManager.readCodexAuth()
            await MainActor.run {
                let manager = AgentUsageManager.shared
                if let claude {
                    var label = "Signed in via Claude Code"
                    if let plan = claude.subscriptionType, !plan.isEmpty {
                        label += " (\(plan))"
                    }
                    manager.claudeAccountLabel = label
                } else {
                    manager.claudeAccountLabel = nil
                }
                if let codex {
                    var label: String
                    if let account = codex.accountId, !account.isEmpty {
                        label = "Account \(String(account.prefix(8)))…"
                    } else {
                        label = "Signed in via Codex CLI"
                    }
                    if codex.expired { label += " — token expired" }
                    manager.codexAccountLabel = label
                } else {
                    manager.codexAccountLabel = nil
                }
            }
        }
    }

    /// True when the given provider's data should render dimmed.
    func isStale(_ provider: AgentProvider) -> Bool {
        let usage = provider == .claude ? claudeUsage : codexUsage
        let status = provider == .claude ? claudeStatus : codexStatus
        if status.isStale { return true }
        if let usage, Date().timeIntervalSince(usage.fetchedAt) > staleAfter { return true }
        return false
    }

    // MARK: Refresh plumbing

    private func refreshProvider(_ provider: AgentProvider, force: Bool) {
        guard !inFlight.contains(provider) else { return }
        if !force, let until = backoffUntil[provider], until > Date() { return }
        inFlight.insert(provider)
        switch provider {
        case .claude: if claudeUsage == nil { claudeStatus = .loading }
        case .codex: if codexUsage == nil { codexStatus = .loading }
        }
        Task { [weak self] in
            guard let self else { return }
            switch provider {
            case .claude: await self.fetchClaude()
            case .codex: await self.fetchCodex()
            }
            self.inFlight.remove(provider)
        }
    }

    private func scheduleBackoff(_ provider: AgentProvider) {
        let interval = backoffInterval[provider] ?? baseBackoff
        backoffUntil[provider] = Date().addingTimeInterval(interval)
        backoffInterval[provider] = min(interval * 2, maxBackoff)
    }

    private func clearBackoff(_ provider: AgentProvider) {
        backoffUntil[provider] = nil
        backoffInterval[provider] = nil
    }

    private func failure(_ provider: AgentProvider, _ message: String, recovery: String) {
        let existing = provider == .claude ? claudeUsage : codexUsage
        let status: AgentUsageStatus = existing != nil
            ? .stale(message)
            : .error(message, recovery: recovery)
        switch provider {
        case .claude: claudeStatus = status
        case .codex: codexStatus = status
        }
    }

    // MARK: Claude fetch

    private func fetchClaude() async {
        let credentials = await Task.detached(priority: .utility) {
            AgentUsageManager.readClaudeCredentials()
        }.value

        guard let token = credentials?.accessToken, !token.isEmpty else {
            failure(.claude, "No Claude Code sign-in found",
                    recovery: "Open Claude Code in a terminal and sign in, then retry.")
            return
        }
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Required: without a claude-code User-Agent this endpoint 429s (research-critic).
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    failure(.claude, "Unexpected usage response", recovery: "Retry")
                    return
                }
                claudeUsage = AgentProviderUsage(
                    windows: Self.parseClaudeWindows(obj),
                    creditsBalance: nil,
                    fetchedAt: Date())
                claudeStatus = .loaded
                clearBackoff(.claude)
            case 401, 403:
                scheduleBackoff(.claude)
                failure(.claude, "Claude token was rejected (\(code))",
                        recovery: "Open Claude Code once so it refreshes its sign-in, then retry.")
            case 429:
                scheduleBackoff(.claude)
                failure(.claude, "Rate limited by the usage endpoint",
                        recovery: "Backing off automatically — retry in a few minutes.")
            default:
                scheduleBackoff(.claude)
                failure(.claude, "Usage endpoint error (HTTP \(code))", recovery: "Retry")
            }
        } catch {
            scheduleBackoff(.claude)
            failure(.claude, "Network error: \(error.localizedDescription)",
                    recovery: "Check your connection and retry.")
        }
    }

    /// five_hour / seven_day{,_opus,_sonnet} {utilization, resets_at} +
    /// limits[] weekly_scoped {percent, resets_at, scope.model.display_name}.
    nonisolated static func parseClaudeWindows(_ obj: [String: Any]) -> [AgentUsageWindow] {
        var windows: [AgentUsageWindow] = []

        func append(_ key: String, _ label: String) {
            guard let w = obj[key] as? [String: Any] else { return }
            let pct = doubleValue(w["utilization"] ?? w["percent"]) ?? 0
            windows.append(AgentUsageWindow(
                id: key, label: label,
                percent: min(max(pct, 0), 100),
                resetsAt: parseDate(w["resets_at"])))
        }
        append("five_hour", "5-hour")
        append("seven_day", "Weekly")
        append("seven_day_opus", "Weekly · Opus")
        append("seven_day_sonnet", "Weekly · Sonnet")

        if let limits = obj["limits"] as? [[String: Any]] {
            for (index, limit) in limits.enumerated()
            where (limit["kind"] as? String) == "weekly_scoped" {
                var label = "Weekly"
                if let scope = limit["scope"] as? [String: Any],
                   let model = scope["model"] as? [String: Any],
                   let name = model["display_name"] as? String, !name.isEmpty {
                    label = "Weekly · \(name)"
                }
                guard !windows.contains(where: { $0.label == label }) else { continue }
                let pct = doubleValue(limit["percent"] ?? limit["utilization"]) ?? 0
                windows.append(AgentUsageWindow(
                    id: "limit-\(index)", label: label,
                    percent: min(max(pct, 0), 100),
                    resetsAt: parseDate(limit["resets_at"])))
            }
        }
        return windows
    }

    // MARK: Codex fetch

    private func fetchCodex() async {
        let auth = await Task.detached(priority: .utility) {
            AgentUsageManager.readCodexAuth()
        }.value

        guard let auth else {
            failure(.codex, "No Codex sign-in found (~/.codex/auth.json)",
                    recovery: "Run `codex login` in a terminal, then retry.")
            return
        }
        if auth.expired {
            failure(.codex, "Codex access token is expired",
                    recovery: "Run `codex` once so it refreshes the token, then retry.")
            return
        }
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        if let account = auth.accountId, !account.isEmpty {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    failure(.codex, "Unexpected usage response", recovery: "Retry")
                    return
                }
                let (windows, credits) = Self.parseCodexUsage(obj)
                codexUsage = AgentProviderUsage(
                    windows: windows, creditsBalance: credits, fetchedAt: Date())
                codexStatus = .loaded
                clearBackoff(.codex)
            case 401, 403:
                scheduleBackoff(.codex)
                failure(.codex, "Codex token was rejected (\(code))",
                        recovery: "Run `codex login` in a terminal, then retry.")
            case 429:
                scheduleBackoff(.codex)
                failure(.codex, "Rate limited by the usage endpoint",
                        recovery: "Backing off automatically — retry in a few minutes.")
            default:
                scheduleBackoff(.codex)
                failure(.codex, "Usage endpoint error (HTTP \(code))", recovery: "Retry")
            }
        } catch {
            scheduleBackoff(.codex)
            failure(.codex, "Network error: \(error.localizedDescription)",
                    recovery: "Check your connection and retry.")
        }
    }

    /// rate_limit.primary_window/secondary_window {used_percent, resets_at |
    /// reset_after_seconds} + credits.balance.
    nonisolated static func parseCodexUsage(_ obj: [String: Any]) -> ([AgentUsageWindow], Double?) {
        var windows: [AgentUsageWindow] = []
        let rateLimit = (obj["rate_limit"] as? [String: Any])
            ?? (obj["rate_limits"] as? [String: Any])

        func append(_ key: String, _ label: String) {
            guard let w = rateLimit?[key] as? [String: Any] else { return }
            let pct = doubleValue(w["used_percent"] ?? w["percent_used"] ?? w["utilization"]) ?? 0
            var resets = parseDate(w["resets_at"] ?? w["reset_at"])
            if resets == nil,
               let seconds = doubleValue(w["reset_after_seconds"] ?? w["resets_in_seconds"]) {
                resets = Date().addingTimeInterval(seconds)
            }
            windows.append(AgentUsageWindow(
                id: key, label: label,
                percent: min(max(pct, 0), 100),
                resetsAt: resets))
        }
        append("primary_window", "5-hour")
        append("secondary_window", "Weekly")

        var credits: Double?
        if let creditsObj = obj["credits"] as? [String: Any] {
            credits = doubleValue(creditsObj["balance"])
        }
        return (windows, credits)
    }

    // MARK: Credential readers (nonisolated, run off-main)

    struct ClaudeCredentials {
        let accessToken: String
        let subscriptionType: String?
    }

    struct CodexAuth {
        let token: String
        let accountId: String?
        let expired: Bool
    }

    /// Keychain via `/usr/bin/security` (no ACL dialog), then
    /// `~/.claude/.credentials.json` fallback.
    nonisolated static func readClaudeCredentials() -> ClaudeCredentials? {
        if let output = runSecurityFindGenericPassword(service: "Claude Code-credentials"),
           let credentials = extractClaudeCredentials(from: output) {
            return credentials
        }
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map {
            ($0 as NSString).expandingTildeInPath
        } ?? (NSHomeDirectory() + "/.claude")
        let path = base + "/.credentials.json"
        if let data = FileManager.default.contents(atPath: path),
           let text = String(data: data, encoding: .utf8),
           let credentials = extractClaudeCredentials(from: text) {
            return credentials
        }
        return nil
    }

    nonisolated private static func extractClaudeCredentials(from raw: String) -> ClaudeCredentials? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let oauth = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
            if let token = oauth["accessToken"] as? String, !token.isEmpty {
                return ClaudeCredentials(
                    accessToken: token,
                    subscriptionType: oauth["subscriptionType"] as? String)
            }
        }
        // Raw token stored directly.
        if trimmed.hasPrefix("sk-ant"), !trimmed.contains(" ") {
            return ClaudeCredentials(accessToken: trimmed, subscriptionType: nil)
        }
        return nil
    }

    nonisolated private static func runSecurityFindGenericPassword(service: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `~/.codex/auth.json` → tokens.access_token (JWT, exp checked locally)
    /// + tokens.account_id.
    nonisolated static func readCodexAuth() -> CodexAuth? {
        let path = NSHomeDirectory() + "/.codex/auth.json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let tokens = (obj["tokens"] as? [String: Any]) ?? obj
        guard let access = tokens["access_token"] as? String, !access.isEmpty else { return nil }
        let accountId = (tokens["account_id"] as? String) ?? (obj["account_id"] as? String)
        var expired = false
        if let exp = jwtExpiry(access) { expired = exp < Date() }
        return CodexAuth(token: access, accountId: accountId, expired: expired)
    }

    /// Decode a JWT's payload (base64url) and read the `exp` claim.
    nonisolated static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let exp = doubleValue(obj["exp"])
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: Small parsing helpers

    nonisolated static func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    // Formatting through ISO8601DateFormatter is thread-safe after configuration.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Accepts ISO8601 strings and epoch seconds/milliseconds.
    nonisolated static func parseDate(_ value: Any?) -> Date? {
        if let s = value as? String {
            return isoFractional.date(from: s) ?? iso.date(from: s)
        }
        if let d = doubleValue(value) {
            let seconds = d > 1e12 ? d / 1000 : d
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}
