import AppKit

/// Every collector NotchLite knows, in display order (Omarchy's agents).
enum Collectors {
    static let all: [UsageCollector] = [
        ClaudeCollector(), CodexCollector(),
        CursorCollector(), GrokBotCollector(), CopilotCollector(), DevinCollector(),
        GrokCollector(), KimiCollector(), MuseCollector(), AntigravityCollector(),
        ZaiCollector(), MiniMaxCollector(), SyntheticCollector(), OllamaCloudCollector(), OpenCodeCollector(),
        OpenRouterCollector(), DeepSeekCollector(), FireworksCollector(), KimchiCollector(),
    ]

    static func collector(_ id: String) -> UsageCollector? { all.first { $0.id == id } }
}

/// Subscription limits, balances and local usage for every coding agent on
/// the Mac, read the way Omarchy's Agents panel reads them. Network checks run
/// every 10 minutes at most; all collectors run concurrently in the background.
@MainActor
final class UsageService: ObservableObject {
    @Published private(set) var usage: [String: AgentUsage] = [:]
    @Published private(set) var stats: [String: LocalStats] = [:]
    @Published private(set) var isRefreshing = false

    /// Called when a limit crosses 90%: (agent display name, limit).
    var onThreshold: ((String, UsageLimit) -> Void)?

    nonisolated static let urgentThreshold = 0.9
    private let limitsInterval: TimeInterval = 600
    private let statsInterval: TimeInterval = 180
    private var limitsFetchedAt: Date?
    private var statsFetchedAt: Date?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "notchlite.usage", qos: .utility)
    private let indexer = StatsIndexer()

    /// Agents in use: those with limits or a balance to show, in registry order.
    var activeAgents: [String] {
        Collectors.all.map(\.id).filter { usage[$0]?.isActive == true }
    }

    var isUrgent: Bool {
        usage.values.contains { $0.limits.contains { $0.percent >= Self.urgentThreshold } }
    }

    #if DEBUG
    func debugSet(usage: [String: AgentUsage], stats: [String: LocalStats]) {
        self.usage = usage
        self.stats = stats
    }
    #endif

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: false) }
        }
        timer.tolerance = 20
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh(force: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Cheap to call often: each source refreshes only when its data is old.
    func refresh(force: Bool, maxLimitsAge: TimeInterval? = nil) {
        guard !isRefreshing else { return }
        let now = Date()
        let limitsDue = force || limitsFetchedAt.map { now.timeIntervalSince($0) >= (maxLimitsAge ?? limitsInterval) } ?? true
        let statsDue = force || statsFetchedAt.map { now.timeIntervalSince($0) >= statsInterval } ?? true
        guard limitsDue || statsDue else { return }

        isRefreshing = true
        let previous = usage
        let indexer = indexer
        queue.async {
            let indexed = statsDue ? indexer.scan() : nil
            let fetched = limitsDue ? Self.fetchAll(previous: previous) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finish(indexed: indexed, usage: fetched, previous: previous)
                }
            }
        }
    }

    /// Runs every collector concurrently; each has its own network timeout.
    private nonisolated static func fetchAll(previous: [String: AgentUsage]) -> [String: AgentUsage] {
        let collectors = Collectors.all
        let results = Locked([String: AgentUsage]())
        DispatchQueue.concurrentPerform(iterations: collectors.count) { index in
            let collector = collectors[index]
            autoreleasepool {
                if let value = collector.fetch(previous: previous[collector.id]) {
                    results.mutate { $0[collector.id] = value }
                }
            }
        }
        return results.value
    }

    private func finish(indexed: [String: LocalStats]?, usage newUsage: [String: AgentUsage]?, previous: [String: AgentUsage]) {
        isRefreshing = false
        let now = Date()
        if let newUsage {
            limitsFetchedAt = now
            for (id, current) in newUsage {
                for limit in current.limits where limit.percent >= Self.urgentThreshold {
                    let before = previous[id]?.limits.first { $0.label == limit.label }?.percent ?? 0
                    if before < Self.urgentThreshold {
                        onThreshold?(Collectors.collector(id)?.displayName ?? id, limit)
                    }
                }
            }
            if newUsage != usage { usage = newUsage }
        }
        // Local stats: Claude/Codex from the transcript index, the others
        // from what their collectors read themselves.
        if indexed != nil { statsFetchedAt = now }
        var merged = indexed ?? stats.filter { $0.key == "claude" || $0.key == "codex" }
        for (id, value) in usage { if let own = value.stats, !own.isEmpty { merged[id] = own } }
        if merged != stats { stats = merged }
    }
}

// MARK: Local stats (incremental transcript index)

/// Reads only what was appended since the last scan, so after the first pass a
/// refresh costs a few milliseconds even with hundreds of MB of history.
/// Not thread-safe: used only from UsageService's serial queue.
private final class StatsIndexer: @unchecked Sendable {
    private struct FileState {
        var offset: UInt64 = 0
        var model: String?
        var session: String?
        var skip = false // Codex rollout on a non-OpenAI provider
        var hasUsageRecords = false
    }

    private struct Day {
        var tokens = 0
        var prompts = 0
        var sessions = Set<String>()
        var models: [String: Int] = [:]
    }

    private var files: [String: FileState] = [:]
    private var days: [String: [String: Day]] = [:]
    private var seen = Set<UInt64>() // hashed keys: a few MB instead of tens
    private let window: TimeInterval = 8 * 86400
    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let iso = ISO8601DateFormatter()

    func scan() -> [String: LocalStats] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cutoff = Date().addingTimeInterval(-window)
        for url in recentFiles(in: home.appendingPathComponent(".claude/projects"), since: cutoff) {
            read(url, agent: .claude)
        }
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        for url in recentFiles(in: codexHome.appendingPathComponent("sessions"), since: cutoff) {
            read(url, agent: .codex)
        }
        prune()
        return summarize()
    }

    private func recentFiles(in directory: URL, since cutoff: Date) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified >= cutoff { result.append(url) }
        }
        return result
    }

    private func read(_ url: URL, agent: AgentName) {
        let path = url.path
        var state = files[path] ?? FileState()
        guard !state.skip,
              let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value else { return }
        if size < state.offset { state = FileState() } // rewritten
        guard size > state.offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.offset)

        var pending = Data()
        while let chunk = autoreleasepool(invoking: { try? handle.read(upToCount: 4 << 20) }), !chunk.isEmpty {
            pending.append(chunk)
            var lineStart = pending.startIndex
            while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
                let line = pending[lineStart..<newline]
                // Release each line's temporary JSON objects right away: the
                // first pass can walk hundreds of MB of history.
                autoreleasepool {
                    switch agent {
                    case .claude: claudeLine(line)
                    case .codex: codexLine(line, state: &state)
                    }
                }
                lineStart = pending.index(after: newline)
                if state.skip { break }
            }
            state.offset += UInt64(lineStart - pending.startIndex)
            pending.removeSubrange(pending.startIndex..<lineStart)
            if state.skip { break }
        }
        files[path] = state
    }

    // Byte patterns checked before paying for JSON parsing.
    private static let usageMarker = Data(#""usage""#.utf8)
    private static let userMarker = Data(#""type":"user""#.utf8)
    private static let codexMarkers = ["token_usage_record", "token_count", "UserMessage", "session_meta", "turn_context"]
        .map { Data($0.utf8) }

    private func claudeLine(_ line: Data) {
        let isUsage = line.range(of: Self.usageMarker) != nil
        let isUser = line.range(of: Self.userMarker) != nil
        guard isUsage || isUser,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let day = day(object["timestamp"]) else { return }
        let type = object["type"] as? String

        if type == "assistant", let message = object["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any] {
            let key = "c:\(message["id"] as? String ?? ""):\(object["requestId"] as? String ?? "")"
            guard key.count > 4, seen.insert(Self.hash(key)).inserted else { return }
            let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .reduce(0) { $0 + Int(number(usage[$1]) ?? 0) }
            let model = message["model"] as? String
            add("claude", day: day, tokens: tokens, model: model == "<synthetic>" ? nil : model)
        } else if type == "user", isTypedClaudePrompt(object) {
            let key = "u:\(object["uuid"] as? String ?? UUID().uuidString)"
            guard seen.insert(Self.hash(key)).inserted else { return }
            add("claude", day: day, prompt: true, session: object["sessionId"] as? String)
        }
    }

    private func isTypedClaudePrompt(_ object: [String: Any]) -> Bool {
        if object["isMeta"] as? Bool == true || object["isSidechain"] as? Bool == true
            || object["isCompactSummary"] as? Bool == true { return false }
        guard let message = object["message"] as? [String: Any] else { return false }
        if let text = message["content"] as? String {
            let machine = ["<task-notification>", "<local-command-", "[Request interrupted", "<command-name>", "<bash-"]
            return !machine.contains { text.hasPrefix($0) }
        }
        if let parts = message["content"] as? [[String: Any]] {
            return !parts.contains { $0["type"] as? String == "tool_result" }
                && parts.contains { $0["type"] as? String == "text" }
        }
        return false
    }

    private func codexLine(_ line: Data, state: inout FileState) {
        guard Self.codexMarkers.contains(where: { line.range(of: $0) != nil }),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let payload = object["payload"] as? [String: Any] ?? [:]
        switch object["type"] as? String {
        case "session_meta":
            state.session = payload["session_id"] as? String ?? payload["id"] as? String
            if let provider = payload["model_provider"] as? String, provider != "openai" { state.skip = true }
        case "turn_context":
            state.model = payload["model"] as? String ?? state.model
        case "token_usage_record":
            state.hasUsageRecords = true
            guard let day = day(object["timestamp"]),
                  let usage = payload["usage"] as? [String: Any] else { return }
            add("codex", day: day, tokens: Int(number(usage["total_tokens"]) ?? 0), model: state.model)
        case "event_msg":
            guard let day = day(object["timestamp"]) else { return }
            if payload["type"] as? String == "token_count", !state.hasUsageRecords,
               let info = payload["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any] {
                add("codex", day: day, tokens: Int(number(last["total_tokens"]) ?? 0), model: state.model)
            } else if payload["type"] as? String == "item_completed",
                      (payload["item"] as? [String: Any])?["type"] as? String == "UserMessage" {
                add("codex", day: day, prompt: true, session: state.session)
            }
        default:
            break
        }
    }

    /// FNV-1a: stable across launches, unlike Hasher.
    private static func hash(_ key: String) -> UInt64 {
        key.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    private func add(_ agent: String, day: String, tokens: Int = 0, model: String? = nil, prompt: Bool = false, session: String? = nil) {
        var entry = days[agent]?[day] ?? Day()
        entry.tokens += tokens
        if let model, tokens > 0 { entry.models[model, default: 0] += tokens }
        if prompt {
            entry.prompts += 1
            if let session { entry.sessions.insert(session) }
        }
        days[agent, default: [:]][day] = entry
    }

    private func day(_ value: Any?) -> String? {
        guard let text = value as? String,
              let date = isoFractional.date(from: text) ?? iso.date(from: text),
              Date().timeIntervalSince(date) < window else { return nil }
        return dayFormatter.string(from: date)
    }

    private func prune() {
        let oldest = dayFormatter.string(from: Date().addingTimeInterval(-window))
        for agent in days.keys { days[agent] = days[agent]?.filter { $0.key >= oldest } }
        if seen.count > 300_000 { seen.removeAll() } // bounded memory; rare double count after
        let cutoff = Date().addingTimeInterval(-window)
        files = files.filter { path, _ in
            ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? .distantPast) >= cutoff
        }
    }

    private func summarize() -> [String: LocalStats] {
        let calendar = Calendar.current
        let today = dayFormatter.string(from: Date())
        let weekStart = dayFormatter.string(from: calendar.date(byAdding: .day, value: -6, to: Date()) ?? Date())
        var result: [String: LocalStats] = [:]
        for (agent, perDay) in days {
            var stats = LocalStats()
            var models: [String: Int] = [:]
            var busiest: (String, Int)?
            for (day, entry) in perDay where day >= weekStart {
                stats.tokensWeek += entry.tokens
                for (model, tokens) in entry.models { models[model, default: 0] += tokens }
                if entry.tokens > (busiest?.1 ?? 0) { busiest = (day, entry.tokens) }
                if day == today {
                    stats.tokensToday = entry.tokens
                    stats.promptsToday = entry.prompts
                    stats.sessionsToday = entry.sessions.count
                }
            }
            stats.topModel = models.max { $0.value < $1.value }?.key
            stats.busiestDay = busiest.flatMap { dayFormatter.date(from: $0.0) }
            if !stats.isEmpty { result[agent] = stats }
        }
        return result
    }
}


private func number(_ value: Any?) -> Double? { Kit.number(value) }

// MARK: Command line report

enum UsageReport {
    /// `NotchLite --usage-report`: runs every collector once and prints the results.
    static func run() {
        var clock = Date()
        let stats = StatsIndexer().scan()
        print(String(format: "Statistiche Claude/Codex: %.2fs", Date().timeIntervalSince(clock)))
        for (id, value) in stats.sorted(by: { $0.key < $1.key }) {
            print("  \(id): oggi \(value.tokensToday) token, \(value.promptsToday) prompt; settimana \(value.tokensWeek) token; top \(value.topModel ?? "-")")
        }
        for collector in Collectors.all {
            clock = Date()
            let result = collector.fetch(previous: nil)
            let elapsed = Date().timeIntervalSince(clock)
            guard let result else {
                print(String(format: "· %@: non usato su questo Mac (%.2fs)", collector.displayName, elapsed))
                continue
            }
            print(String(format: "%@ %@ (%.2fs) piano: %@", result.isActive ? "●" : "○", collector.displayName,
                         elapsed, result.plan ?? "-"))
            for limit in result.limits {
                print("    \(limit.label): \(Int(limit.percent * 100))%  reset \(limit.resetsAt.map { "\($0)" } ?? "-")")
            }
            if let balance = result.balance { print("    credito: \(balance)") }
            if let note = result.note { print("    nota: \(note)") }
            if let extra = result.extra { print("    \(extra)") }
            if let own = result.stats {
                print("    statistiche: oggi \(own.tokensToday) token, \(own.promptsToday) prompt; settimana \(own.tokensWeek); top \(own.topModel ?? "-")")
            }
        }
    }
}
