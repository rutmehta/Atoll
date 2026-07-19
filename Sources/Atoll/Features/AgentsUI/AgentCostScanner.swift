import Foundation
import Combine

// MARK: - Value types

/// Token counts for one day × model bucket.
struct AgentTokenTally: Codable, Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    var totalTokens: Int { input + output + cacheRead + cacheWrite }

    mutating func add(input: Int, output: Int, cacheRead: Int, cacheWrite: Int) {
        self.input += input
        self.output += output
        self.cacheRead += cacheRead
        self.cacheWrite += cacheWrite
    }
}

/// USD per 1M tokens.
struct AgentModelPrice: Codable, Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double

    func cost(of tally: AgentTokenTally) -> Double {
        (Double(tally.input) * input
            + Double(tally.output) * output
            + Double(tally.cacheRead) * cacheRead
            + Double(tally.cacheWrite) * cacheWrite) / 1_000_000
    }
}

/// One day in the 30-day dashboard.
struct AgentDayCost: Identifiable, Equatable {
    /// "yyyy-MM-dd" (local timezone) — also the id.
    let dayKey: String
    let day: Date
    /// model → USD spent that day.
    var perModelUSD: [String: Double]
    var tokens: Int

    var totalUSD: Double { perModelUSD.values.reduce(0, +) }
    var id: String { dayKey }
}

// MARK: - Scanner

/// Incremental cost scanner over `~/.claude/projects/**/*.jsonl` and
/// `~/.codex/sessions/**/*.jsonl` (+ archived_sessions), with a per-file
/// {size, mtime, offset} cache persisted to Application Support. Prices come
/// from a bundled fallback table, overridden by models.dev/api.json when it
/// is reachable (10 s timeout).
@MainActor
final class AgentCostScanner: ObservableObject {
    static let shared = AgentCostScanner()

    /// Exactly 30 entries, oldest first, zero-filled for missing days.
    @Published private(set) var days: [AgentDayCost] = []
    @Published private(set) var totalUSD30: Double = 0
    @Published private(set) var todayUSD: Double = 0
    @Published private(set) var totalTokens30: Int = 0
    /// Models seen in the window, sorted by spend (desc) — drives colors/legend.
    @Published private(set) var modelsSeen: [String] = []
    @Published private(set) var scanning = false
    @Published private(set) var lastScanAt: Date?

    private var cacheSnapshot: ScanCache?
    private var priceTable: [String: AgentModelPrice]
    private var priceKeysByLength: [String]
    private var remotePricingAttempted = false

    init() {
        priceTable = Self.fallbackPrices
        priceKeysByLength = Self.fallbackPrices.keys.sorted { $0.count > $1.count }
    }

    // MARK: Public API

    /// Kick off an incremental scan (throttled to once per minute unless forced).
    func rescan(force: Bool = false) {
        guard !scanning else { return }
        if !force, let last = lastScanAt, Date().timeIntervalSince(last) < 60 { return }
        scanning = true
        loadRemotePricingIfNeeded()

        let snapshot = cacheSnapshot
        let cacheURL = Self.cacheFileURL
        Task.detached(priority: .utility) {
            let loaded = snapshot ?? Self.loadCache(from: cacheURL) ?? ScanCache()
            let updated = Self.scanWork(startingFrom: loaded)
            Self.saveCache(updated, to: cacheURL)
            await MainActor.run {
                let scanner = AgentCostScanner.shared
                scanner.cacheSnapshot = updated
                scanner.republish()
                scanner.scanning = false
                scanner.lastScanAt = Date()
            }
        }
    }

    // MARK: Pricing

    /// Bundled fallback (USD per 1M tokens). Longest-prefix matched against
    /// transcript model ids; overridden by models.dev when reachable.
    nonisolated static let fallbackPrices: [String: AgentModelPrice] = [
        // Anthropic
        "claude-opus-4-5": .init(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-1": .init(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75),
        "claude-opus-4": .init(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75),
        "claude-sonnet-4-5": .init(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "claude-sonnet-4": .init(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "claude-haiku-4-5": .init(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
        "claude-3-7-sonnet": .init(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "claude-3-5-sonnet": .init(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "claude-3-5-haiku": .init(input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1),
        // OpenAI (gpt-5 family; cacheWrite is free)
        "gpt-5.1-codex-max": .init(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0),
        "gpt-5.1-codex-mini": .init(input: 0.25, output: 2, cacheRead: 0.025, cacheWrite: 0),
        "gpt-5.1-codex": .init(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0),
        "gpt-5.1": .init(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0),
        "gpt-5-codex": .init(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0),
        "gpt-5-mini": .init(input: 0.25, output: 2, cacheRead: 0.025, cacheWrite: 0),
        "gpt-5-nano": .init(input: 0.05, output: 0.4, cacheRead: 0.005, cacheWrite: 0),
        "gpt-5-pro": .init(input: 15, output: 120, cacheRead: 0, cacheWrite: 0),
        "gpt-5": .init(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0),
        "gpt-4.1-mini": .init(input: 0.4, output: 1.6, cacheRead: 0.1, cacheWrite: 0),
        "gpt-4.1": .init(input: 2, output: 8, cacheRead: 0.5, cacheWrite: 0),
        "gpt-4o": .init(input: 2.5, output: 10, cacheRead: 1.25, cacheWrite: 0),
    ]

    nonisolated static func price(for model: String,
                                  table: [String: AgentModelPrice],
                                  keysByLength: [String]) -> AgentModelPrice? {
        var norm = model.lowercased()
        if let slash = norm.lastIndex(of: "/") { norm = String(norm[norm.index(after: slash)...]) }
        if let exact = table[norm] { return exact }
        for key in keysByLength where norm.hasPrefix(key) { return table[key] }
        return nil
    }

    private func loadRemotePricingIfNeeded() {
        guard !remotePricingAttempted else { return }
        remotePricingAttempted = true
        Task.detached(priority: .utility) {
            guard let url = URL(string: "https://models.dev/api.json") else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return }
            var overrides: [String: AgentModelPrice] = [:]
            for providerId in ["anthropic", "openai"] {
                guard let provider = root[providerId] as? [String: Any],
                      let models = provider["models"] as? [String: Any] else { continue }
                for (modelId, value) in models {
                    guard let model = value as? [String: Any],
                          let cost = model["cost"] as? [String: Any],
                          let input = AgentUsageManager.doubleValue(cost["input"]),
                          let output = AgentUsageManager.doubleValue(cost["output"])
                    else { continue }
                    overrides[modelId.lowercased()] = AgentModelPrice(
                        input: input,
                        output: output,
                        cacheRead: AgentUsageManager.doubleValue(cost["cache_read"]) ?? 0,
                        cacheWrite: AgentUsageManager.doubleValue(cost["cache_write"]) ?? 0)
                }
            }
            guard !overrides.isEmpty else { return }
            let finalOverrides = overrides
            await MainActor.run {
                AgentCostScanner.shared.applyPricingOverrides(finalOverrides)
            }
        }
    }

    private func applyPricingOverrides(_ overrides: [String: AgentModelPrice]) {
        priceTable.merge(overrides) { _, new in new }
        priceKeysByLength = priceTable.keys.sorted { $0.count > $1.count }
        republish()
    }

    // MARK: Publish

    private func republish() {
        guard let cache = cacheSnapshot else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let todayKey = Self.dayKey(for: today)

        var result: [AgentDayCost] = []
        var spendByModel: [String: Double] = [:]
        var total: Double = 0
        var tokens = 0

        for offset in (0..<30).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = Self.dayKey(for: date)
            var perModel: [String: Double] = [:]
            var dayTokens = 0
            if let bucket = cache.buckets[key] {
                for (model, tally) in bucket {
                    let price = Self.price(for: model, table: priceTable,
                                           keysByLength: priceKeysByLength)
                    let usd = price?.cost(of: tally) ?? 0
                    perModel[model, default: 0] += usd
                    spendByModel[model, default: 0] += usd
                    dayTokens += tally.totalTokens
                }
            }
            total += perModel.values.reduce(0, +)
            tokens += dayTokens
            result.append(AgentDayCost(dayKey: key, day: date,
                                       perModelUSD: perModel, tokens: dayTokens))
        }

        days = result
        totalUSD30 = total
        totalTokens30 = tokens
        todayUSD = result.first(where: { $0.dayKey == todayKey })?.totalUSD ?? 0
        modelsSeen = spendByModel.sorted { $0.value > $1.value }.map(\.key)
    }

    // MARK: - Persistent cache

    fileprivate struct ScanCache: Codable {
        struct FileState: Codable {
            var size: UInt64
            var mtime: TimeInterval
            var offset: UInt64
            /// Codex rollouts: current model carried across incremental reads.
            var model: String?
            /// Codex rollouts: last-seen cumulative total_token_usage components.
            /// Real rollouts repeat every token_count event twice with identical
            /// cumulative totals — tallying deltas (skipping zero deltas) instead
            /// of last_token_usage avoids double counting.
            var prevInput: Int?
            var prevCached: Int?
            var prevOutput: Int?
        }

        var files: [String: FileState] = [:]
        /// dayKey → model → tally.
        var buckets: [String: [String: AgentTokenTally]] = [:]
        /// dayKey → dedupe ids ("messageId|requestId") seen that day.
        var dedupe: [String: Set<String>] = [:]
    }

    nonisolated static var cacheFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atoll", isDirectory: true)
            .appendingPathComponent("agent-cost-cache.json")
    }

    nonisolated fileprivate static func loadCache(from url: URL) -> ScanCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ScanCache.self, from: data)
    }

    nonisolated fileprivate static func saveCache(_ cache: ScanCache, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(cache)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Atoll: cost cache save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Scan worker (off-main)

    nonisolated fileprivate static func scanWork(startingFrom initial: ScanCache) -> ScanCache {
        var cache = initial
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-31 * 86_400)

        struct Candidate {
            let path: String
            let size: UInt64
            let mtime: Date
            let provider: AgentProvider
        }

        var candidates: [Candidate] = []
        for (root, provider) in scanRoots() {
            guard let enumerator = fm.enumerator(atPath: root) else { continue }
            while let rel = enumerator.nextObject() as? String {
                guard rel.hasSuffix(".jsonl") else { continue }
                let path = root + "/" + rel
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date,
                      let size = (attrs[.size] as? NSNumber)?.uint64Value
                else { continue }
                // A file older than the window can't contain in-window entries.
                guard mtime > cutoff else { continue }
                candidates.append(Candidate(path: path, size: size, mtime: mtime, provider: provider))
            }
        }

        // Any shrunk file invalidates the incremental math — full rescan.
        let shrank = candidates.contains { candidate in
            if let state = cache.files[candidate.path] { return candidate.size < state.size }
            return false
        }
        if shrank { cache = ScanCache() }

        for candidate in candidates {
            let prior = cache.files[candidate.path]
            if let prior,
               prior.size == candidate.size,
               abs(prior.mtime - candidate.mtime.timeIntervalSince1970) < 0.5 {
                continue // unchanged
            }
            // Rollout basenames are unique (uuid-stamped); when a Codex file
            // moves from sessions/ to archived_sessions/ carry its state over so
            // the content is not re-counted at the new path.
            var effectivePrior = prior
            if effectivePrior == nil, candidate.provider == .codex {
                let basename = (candidate.path as NSString).lastPathComponent
                if let (oldPath, moved) = cache.files.first(where: {
                    ($0.key as NSString).lastPathComponent == basename && $0.key != candidate.path
                }) {
                    effectivePrior = moved
                    cache.files.removeValue(forKey: oldPath)
                }
            }
            if let effectivePrior,
               effectivePrior.size == candidate.size,
               abs(effectivePrior.mtime - candidate.mtime.timeIntervalSince1970) < 0.5 {
                cache.files[candidate.path] = effectivePrior
                continue
            }
            var codexState = CodexScanState(
                model: effectivePrior?.model,
                prevInput: effectivePrior?.prevInput,
                prevCached: effectivePrior?.prevCached,
                prevOutput: effectivePrior?.prevOutput)
            let startOffset = effectivePrior?.offset ?? 0
            let newOffset = forEachLine(path: candidate.path, from: startOffset) { line in
                switch candidate.provider {
                case .claude:
                    ingestClaudeLine(line, into: &cache, cutoff: cutoff)
                case .codex:
                    ingestCodexLine(line, into: &cache, state: &codexState, cutoff: cutoff)
                }
            }
            cache.files[candidate.path] = ScanCache.FileState(
                size: candidate.size,
                mtime: candidate.mtime.timeIntervalSince1970,
                offset: newOffset,
                model: codexState.model,
                prevInput: codexState.prevInput,
                prevCached: codexState.prevCached,
                prevOutput: codexState.prevOutput)
        }

        prune(&cache, cutoff: cutoff)
        return cache
    }

    nonisolated private static func scanRoots() -> [(String, AgentProvider)] {
        let claudeBase = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map {
            ($0 as NSString).expandingTildeInPath
        } ?? (NSHomeDirectory() + "/.claude")
        return [
            (claudeBase + "/projects", .claude),
            (NSHomeDirectory() + "/.codex/sessions", .codex),
            (NSHomeDirectory() + "/.codex/archived_sessions", .codex),
        ]
    }

    /// Stream complete lines from `offset`; returns the offset just past the
    /// last complete line (partial trailing lines are re-read next scan).
    nonisolated private static func forEachLine(path: String, from offset: UInt64,
                                                handler: (Data) -> Void) -> UInt64 {
        guard let handle = FileHandle(forReadingAtPath: path) else { return offset }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch { return offset }

        var consumed = offset
        var carry = Data()
        let newline: UInt8 = 0x0A

        while true {
            guard let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty else { break }
            let data = carry + chunk
            carry = Data()
            var start = data.startIndex
            while let idx = data[start...].firstIndex(of: newline) {
                if idx > start {
                    handler(Data(data[start..<idx]))
                }
                consumed += UInt64(idx - start) + 1
                start = data.index(after: idx)
            }
            if start < data.endIndex {
                carry = Data(data[start...])
            }
        }
        return consumed
    }

    // MARK: Claude line

    /// `{"type":"assistant","timestamp":…,"requestId":…,"message":{"id":…,
    /// "model":…,"usage":{input_tokens,…}}}` — dedupe on message.id|requestId.
    nonisolated private static func ingestClaudeLine(_ line: Data, into cache: inout ScanCache,
                                                     cutoff: Date) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return }

        let model = (message["model"] as? String) ?? "unknown"
        guard model != "<synthetic>" else { return }
        guard let timestamp = AgentUsageManager.parseDate(obj["timestamp"]), timestamp > cutoff
        else { return }

        let key = dayKey(for: timestamp)
        let messageId = (message["id"] as? String) ?? ""
        let requestId = (obj["requestId"] as? String) ?? ""
        let dedupeKey = "\(messageId)|\(requestId)"
        if dedupeKey != "|" {
            if cache.dedupe[key]?.contains(dedupeKey) == true { return }
            cache.dedupe[key, default: []].insert(dedupeKey)
        }

        var tally = cache.buckets[key]?[model] ?? AgentTokenTally()
        tally.add(
            input: intValue(usage["input_tokens"]),
            output: intValue(usage["output_tokens"]),
            cacheRead: intValue(usage["cache_read_input_tokens"]),
            cacheWrite: intValue(usage["cache_creation_input_tokens"]))
        cache.buckets[key, default: [:]][model] = tally
    }

    // MARK: Codex line

    /// Per-file scan state carried across incremental reads of a Codex rollout.
    struct CodexScanState {
        var model: String?
        var prevInput: Int?
        var prevCached: Int?
        var prevOutput: Int?
    }

    /// Rollout lines: `turn_context`/`session_meta` carry the model;
    /// `event_msg` + payload.type == "token_count" carries cumulative
    /// `info.total_token_usage` and per-event `info.last_token_usage`.
    /// Tally deltas of the cumulative totals: real rollouts emit each
    /// token_count twice (identical totals → zero delta → skipped), and
    /// reasoning tokens are already a subset of output_tokens.
    nonisolated private static func ingestCodexLine(_ line: Data, into cache: inout ScanCache,
                                                    state: inout CodexScanState, cutoff: Date) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let payload = (obj["payload"] as? [String: Any]) ?? [:]
        let type = (obj["type"] as? String) ?? ""

        if type == "turn_context" || type == "session_meta" {
            if let m = payload["model"] as? String, !m.isEmpty { state.model = m }
            return
        }
        guard type == "event_msg", (payload["type"] as? String) == "token_count",
              let info = payload["info"] as? [String: Any]
        else { return }
        let lastUsage = (info["last_token_usage"] as? [String: Any])
            ?? (payload["last_token_usage"] as? [String: Any])

        let input: Int
        let cached: Int
        let output: Int
        if let totals = info["total_token_usage"] as? [String: Any] {
            let curInput = intValue(totals["input_tokens"])
            let curCached = intValue(totals["cached_input_tokens"])
            let curOutput = intValue(totals["output_tokens"])
            defer {
                state.prevInput = curInput
                state.prevCached = curCached
                state.prevOutput = curOutput
            }
            if let prevInput = state.prevInput,
               let prevCached = state.prevCached,
               let prevOutput = state.prevOutput {
                let dInput = curInput - prevInput
                let dCached = curCached - prevCached
                let dOutput = curOutput - prevOutput
                if dInput == 0 && dOutput == 0 { return }        // duplicate event
                if dInput < 0 || dOutput < 0 || dCached < 0 {    // totals reset
                    input = intValue(lastUsage?["input_tokens"])
                    cached = intValue(lastUsage?["cached_input_tokens"])
                    output = intValue(lastUsage?["output_tokens"])
                } else {
                    input = dInput
                    cached = dCached
                    output = dOutput
                }
            } else {
                input = curInput
                cached = curCached
                output = curOutput
            }
        } else if let lastUsage {
            input = intValue(lastUsage["input_tokens"])
            cached = intValue(lastUsage["cached_input_tokens"])
            output = intValue(lastUsage["output_tokens"])
        } else {
            return
        }
        guard input + output > 0 else { return }
        guard let timestamp = AgentUsageManager.parseDate(obj["timestamp"]), timestamp > cutoff
        else { return }

        let key = dayKey(for: timestamp)
        let modelName = state.model ?? "gpt-5-codex"
        var tally = cache.buckets[key]?[modelName] ?? AgentTokenTally()
        tally.add(
            input: max(0, input - cached),
            output: output,
            cacheRead: cached,
            cacheWrite: 0)
        cache.buckets[key, default: [:]][modelName] = tally
    }

    // MARK: Housekeeping

    nonisolated private static func prune(_ cache: inout ScanCache, cutoff: Date) {
        let cutoffKey = dayKey(for: cutoff)
        cache.buckets = cache.buckets.filter { $0.key >= cutoffKey }
        cache.dedupe = cache.dedupe.filter { $0.key >= cutoffKey }
        // Drop file states for files that vanished (keeps the cache bounded).
        let fm = FileManager.default
        cache.files = cache.files.filter { fm.fileExists(atPath: $0.key) }
    }

    nonisolated private static func intValue(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let d = value as? Double { return Int(d) }
        return 0
    }

    nonisolated private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    nonisolated static func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }
}
