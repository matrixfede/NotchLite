// Grok, Kimi Code, Muse and Antigravity collectors, ported from Omarchy (MIT, basecamp/omarchy).

import Foundation

// MARK: Shared helpers

/// The last good answer with a note saying why it isn't current.
private func keptUsage(_ previous: AgentUsage?, note: String, plan: String? = nil,
                       stats: LocalStats? = nil) -> AgentUsage {
    var usage = previous ?? AgentUsage()
    usage.note = note
    if let plan { usage.plan = plan }
    usage.stats = stats ?? usage.stats
    return usage
}

/// ISO times with more fractional digits than Foundation reads (Go and Kimi
/// write nanoseconds), zoneless times as UTC, or epoch numbers.
private func looseDate(_ value: Any?) -> Date? {
    guard var text = value as? String else { return Kit.date(value) }
    text = text.trimmingCharacters(in: .whitespaces)
    if let dot = text.firstIndex(of: "."), text.contains("T") {
        let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
        let rest = text[text.index(after: dot)...].dropFirst(digits.count)
        text = String(text[..<dot]) + (digits.isEmpty ? "" : "." + digits.prefix(3)) + rest
    }
    if text.contains("T"), !text.hasSuffix("Z"), text.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) == nil {
        text += "Z"
    }
    return Kit.date(text)
}

private func object(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }

private func count(_ value: Any?) -> Int {
    guard let number = Kit.number(value), number > 0, number < 1e15 else { return 0 }
    return Int(number)
}

private func subdirectories(_ url: URL) -> [URL] {
    let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsHiddenFiles])) ?? []
    return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
}

private func recent(_ url: URL, days: Double = 8) -> Bool {
    guard let modified = Kit.modified(url) else { return false }
    return Date().timeIntervalSince(modified) < days * 86_400
}

/// Lines of a JSONL file that contain one of `markers`, parsed one at a time.
private func jsonLines(_ url: URL, markers: [String], _ body: ([String: Any]) -> Void) {
    guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return }
    let needles = markers.map { Data($0.utf8) }
    var start = data.startIndex
    while start < data.endIndex {
        let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
        let line = data[start..<end]
        start = end < data.endIndex ? data.index(after: end) : end
        guard needles.isEmpty || needles.contains(where: { line.range(of: $0) != nil }) else { continue }
        autoreleasepool {
            if let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { body(entry) }
        }
    }
}

/// Per-day totals for the last 7 local days, turned into `LocalStats`.
private struct StatsTally {
    private let formatter: DateFormatter
    private var tokensByDay: [String: Int] = [:]
    private var models: [String: Int] = [:]
    private var promptsToday = 0
    private var sessionsToday = Set<String>()
    private let today: String
    private let weekStart: String

    init() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        self.formatter = formatter
        today = formatter.string(from: Date())
        weekStart = formatter.string(from: Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date())
    }

    func day(_ date: Date?) -> String? {
        guard let date else { return nil }
        let day = formatter.string(from: date)
        return day >= weekStart && day <= today ? day : nil
    }

    mutating func tokens(_ amount: Int, on date: Date?, model: String?, session: String? = nil) {
        guard amount > 0, let day = day(date) else { return }
        tokensByDay[day, default: 0] += amount
        if let model, !model.isEmpty { models[model, default: 0] += amount }
        if day == today, let session { sessionsToday.insert(session) }
    }

    mutating func prompt(on date: Date?, session: String?, counts: Bool = true) {
        guard day(date) == today else { return }
        if counts { promptsToday += 1 }
        if let session { sessionsToday.insert(session) }
    }

    mutating func session(_ id: String, activeOn date: Date?) {
        if day(date) == today { sessionsToday.insert(id) }
    }

    var stats: LocalStats? {
        var stats = LocalStats()
        stats.tokensWeek = tokensByDay.values.reduce(0, +)
        stats.tokensToday = tokensByDay[today] ?? 0
        stats.promptsToday = promptsToday
        stats.sessionsToday = sessionsToday.count
        stats.topModel = models.max { $0.value < $1.value }?.key
        stats.busiestDay = tokensByDay.max { $0.value < $1.value }.flatMap { formatter.date(from: $0.key) }
        return stats.isEmpty && stats.sessionsToday == 0 ? nil : stats
    }
}

// MARK: Grok

/// Plan from Grok's cached settings, limit from the credits endpoint behind
/// its `/usage` view, local stats from each session's usage.json.
struct GrokCollector: UsageCollector {
    let id = "grok"
    let displayName = "Grok"
    let symbol = "bolt.horizontal"

    private static let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let monthlyURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!

    func fetch(previous: AgentUsage?) -> AgentUsage? {
        let home = Kit.env("GROK_HOME").map(Kit.expand) ?? Kit.home.appendingPathComponent(".grok")
        let login = Self.login(home)
        let stats = Self.localStats(home)
        guard Kit.exists(home) || login != nil || Kit.which("grok") != nil else { return nil }
        let plan = Self.plan(home)

        guard let login, let token = login["key"] as? String, !token.isEmpty else {
            return AgentUsage(plan: plan, note: "Accesso richiesto: avvia `grok` o esegui `grok login`", stats: stats)
        }
        if let expires = looseDate(login["expires_at"]), expires <= Date() {
            // Grok renews its 6-hour token from the refresh token when it starts (30 days).
            let renewable = (login["refresh_token"] as? String).map { !$0.isEmpty } == true
                && Date().timeIntervalSince(expires) < 30 * 86_400
            return keptUsage(previous, note: renewable ? "Accesso scaduto: apri `grok` per rinnovarlo"
                                                       : "Accesso scaduto: esegui `grok login`",
                             plan: plan, stats: stats)
        }

        let headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        let credits = Kit.request(Self.creditsURL, headers: headers, timeout: 8)
        guard credits.ok, let config = credits.object?["config"] as? [String: Any] else {
            let note = credits.ok ? "Grok ha risposto senza un limite leggibile"
                : Kit.failureNote(credits, provider: "Grok", signIn: "esegui `grok login`")
            return keptUsage(previous, note: note, plan: plan, stats: stats)
        }
        let unified = (config["isUnifiedBillingUser"] as? Bool) == true
        var limits: [UsageLimit] = []
        let main = Self.creditsLimit(config)
        if let main { limits.append(main) }
        if main == nil || (unified && main?.label == "Settimana") {
            let monthly = Kit.request(Self.monthlyURL, headers: headers, timeout: 8)
            if let limit = Self.monthlyLimit(object(monthly.object?["config"])) { limits.append(limit) }
        }
        guard !limits.isEmpty else {
            return keptUsage(previous, note: "Grok ha risposto senza un limite leggibile", plan: plan, stats: stats)
        }
        return AgentUsage(plan: plan, limits: limits, stats: stats, fetchedAt: Date())
    }

    private static func login(_ home: URL) -> [String: Any]? {
        Kit.readJSON(home.appendingPathComponent("auth.json"))?.values.lazy.compactMap { $0 as? [String: Any] }.first
    }

    private static func plan(_ home: URL) -> String? {
        guard let payload = Kit.readJSON(home.appendingPathComponent("settings_cache.json"))?["payload"] as? String,
              let settings = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
              let tier = object(settings["settings"])["subscription_tier_display"] as? String,
              !tier.isEmpty else { return nil }
        return Kit.capitalized(tier)
    }

    /// A number, or a protobuf money field `{"val": n}` whose zero is left out.
    private static func amount(_ value: Any?) -> Double? {
        if let money = value as? [String: Any] { return Kit.number(money["val"]) ?? 0 }
        return Kit.number(value)
    }

    private static func creditsLimit(_ config: [String: Any]) -> UsageLimit? {
        let period = object(config["currentPeriod"])
        let ends = looseDate(period["end"])
        var used = amount(config["creditUsagePercent"])
        if used == nil {
            // Protobuf JSON leaves a zero out; unified billing counts monthly instead.
            if (config["isUnifiedBillingUser"] as? Bool) == true { return nil }
            guard let ends, ends > Date() else { return nil }
            used = 0
        }
        let label = String(describing: period["type"] ?? "").contains("WEEK") ? "Settimana" : "Mese"
        return UsageLimit(label: label, percent: Kit.clamp((used ?? 0) / 100), resetsAt: ends)
    }

    private static func monthlyLimit(_ config: [String: Any]) -> UsageLimit? {
        guard let quota = amount(config["monthlyLimit"]), quota > 0, let used = amount(config["used"]) else { return nil }
        return UsageLimit(label: "Mese", percent: Kit.clamp(used / quota), resetsAt: looseDate(config["billingPeriodEnd"]))
    }

    /// Tokens by model per finished turn; a turn is a typed prompt except in a
    /// subagent's session, and a fork's copied turns count once.
    private static func localStats(_ home: URL) -> LocalStats? {
        var tally = StatsTally()
        var seen = Set<String>()
        for folder in subdirectories(home.appendingPathComponent("sessions")) {
            for session in subdirectories(folder) {
                let usageFile = session.appendingPathComponent("usage.json")
                let summaryFile = session.appendingPathComponent("summary.json")
                guard recent(usageFile) || recent(summaryFile) else { continue }
                autoreleasepool {
                    let summary = Kit.readJSON(summaryFile) ?? [:]
                    let subagent = (summary["session_kind"] as? String)?.hasPrefix("subagent") == true
                    tally.session(session.path, activeOn: looseDate(summary["last_active_at"]))
                    let turns = Kit.readJSON(usageFile)?["turns"] as? [[String: Any]] ?? []
                    for turn in turns {
                        guard let ended = looseDate(turn["endedAt"]), tally.day(ended) != nil else { continue }
                        let buckets = object(turn["modelUsage"])
                        let copy = [turn["endedAt"] ?? NSNull(), buckets]
                        let key = (try? JSONSerialization.data(withJSONObject: copy, options: .sortedKeys))
                            .map { String(decoding: $0, as: UTF8.self) } ?? UUID().uuidString
                        guard seen.insert(key).inserted else { continue }
                        tally.prompt(on: ended, session: session.path, counts: !subagent)
                        for (model, value) in buckets {
                            let bucket = object(value)
                            // Grok counts cached input inside inputTokens.
                            let cached = count(bucket["cachedReadTokens"])
                            let tokens = max(0, count(bucket["inputTokens"]) - cached) + cached
                                + count(bucket["outputTokens"]) + count(bucket["cacheCreationTokens"])
                            tally.tokens(tokens, on: ended, model: model, session: session.path)
                        }
                    }
                }
            }
        }
        return tally.stats
    }
}

// MARK: Kimi Code

/// Kimi Code quotas (5-hour, weekly, monthly) from its usages endpoint, local
/// stats from Kimi Code 2.x's per-agent wire.jsonl logs. Never refreshes the
/// token: that belongs to the `kimi` CLI.
struct KimiCollector: UsageCollector {
    let id = "kimi"
    let displayName = "Kimi Code"
    let symbol = "moon.stars"

    private static let defaultUsageURL = "https://api.kimi.com/coding/v1/usages"

    func fetch(previous: AgentUsage?) -> AgentUsage? {
        let codeHome = Kit.env("KIMI_CODE_HOME").map(Kit.expand) ?? Kit.home.appendingPathComponent(".kimi-code")
        let legacyHome = Kit.env("KIMI_SHARE_DIR").map(Kit.expand) ?? Kit.home.appendingPathComponent(".kimi")
        let credentials = Self.credentialsFile(codeHome: codeHome, legacyHome: legacyHome)
        let envKey = Kit.env("KIMI_API_KEY")
        let stored = Kit.readJSON(credentials) ?? [:]
        let inUse = envKey != nil || Kit.exists(credentials) || Kit.exists(codeHome)
            || (Kit.env("KIMI_CODE_HOME") == nil && Kit.exists(legacyHome))
        guard inUse else { return nil }
        let stats = Self.localStats(codeHome.appendingPathComponent("sessions"))

        let token: String
        if let envKey {
            token = envKey
        } else {
            guard let access = stored["access_token"] as? String, !access.isEmpty else {
                return AgentUsage(note: "Accesso richiesto: esegui `kimi login`", stats: stats)
            }
            let expiry = Kit.number(stored["expires_at"]) ?? 0
            if expiry != 0 && expiry - 60 <= Date().timeIntervalSince1970 {
                return keptUsage(previous, note: "Accesso scaduto: apri `kimi` per rinnovarlo", stats: stats)
            }
            token = access
        }

        let response = Kit.request(Self.usageURL(), headers: ["Authorization": "Bearer \(token)",
                                                              "Accept": "application/json"], timeout: 15)
        let signIn = envKey != nil ? "aggiorna KIMI_API_KEY" : "esegui `kimi login`"
        guard response.ok, let data = response.object,
              data["usages"] != nil || data["usage"] != nil || data["limits"] != nil else {
            let note = response.status == 404 ? "Endpoint di utilizzo Kimi non disponibile"
                : response.ok ? "Kimi ha risposto senza dati di utilizzo"
                : Kit.failureNote(response, provider: "Kimi", signIn: signIn)
            return keptUsage(previous, note: note, stats: stats)
        }
        return AgentUsage(limits: Self.limits(data), stats: stats, fetchedAt: Date())
    }

    /// KIMI_CODE_HOME's own sign-in only; else ~/.kimi-code, then the legacy kimi-cli's.
    private static func credentialsFile(codeHome: URL, legacyHome: URL) -> URL {
        let own = codeHome.appendingPathComponent("credentials/kimi-code.json")
        if Kit.env("KIMI_CODE_HOME") != nil || Kit.exists(own) { return own }
        let legacy = legacyHome.appendingPathComponent("credentials/kimi-code.json")
        return Kit.exists(legacy) ? legacy : own
    }

    /// The token goes only to Kimi's own HTTPS hosts; an override elsewhere is ignored.
    private static func usageURL() -> URL {
        let candidate = Kit.env("KIMI_USAGE_URL")
            ?? Kit.env("KIMI_CODE_BASE_URL").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/usages" }
        if let candidate, let url = URL(string: candidate), url.scheme == "https", url.user == nil,
           let host = url.host?.lowercased(),
           ["kimi.com", "kimi.ai"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return url
        }
        return URL(string: defaultUsageURL)!
    }

    private static func reset(_ detail: [String: Any]) -> Date? {
        for key in ["reset_at", "resetAt", "reset_time", "resetTime"] {
            if let date = looseDate(detail[key]) { return date }
        }
        return nil
    }

    private static func limits(_ data: [String: Any]) -> [UsageLimit] {
        if let usages = data["usages"] as? [String: Any] {
            let windows = [("limit_5h", "Sessione (5 ore)"), ("limit_7d", "Settimana"),
                           ("limit_month_total", "Mese"), ("limit_month_code", "Mese · codice")]
            return windows.compactMap { key, label in
                let detail = object(usages[key])
                guard let ratio = Kit.number(detail["used_ratio"]) else { return nil }
                return UsageLimit(label: label, percent: Kit.clamp(ratio), resetsAt: reset(detail))
            }
        }
        var limits: [UsageLimit] = []
        if let usage = data["usage"] as? [String: Any], let row = row(usage, label: "Settimana") { limits.append(row) }
        for (index, entry) in (data["limits"] as? [[String: Any]] ?? []).enumerated() {
            let detail = entry["detail"] as? [String: Any] ?? entry
            let window = object(entry["window"])
            if let row = row(detail, label: windowLabel(entry, detail, window, index)) { limits.append(row) }
        }
        return limits
    }

    private static func row(_ detail: [String: Any], label: String) -> UsageLimit? {
        guard let limit = Kit.number(detail["limit"]), limit > 0 else { return nil }
        guard let used = Kit.number(detail["used"]) ?? Kit.number(detail["remaining"]).map({ limit - $0 }) else { return nil }
        let name = (detail["name"] as? String) ?? (detail["title"] as? String) ?? label
        return UsageLimit(label: name, percent: Kit.clamp(used / limit), resetsAt: reset(detail))
    }

    private static func windowLabel(_ item: [String: Any], _ detail: [String: Any], _ window: [String: Any],
                                    _ index: Int) -> String {
        for key in ["name", "title", "scope"] {
            if let value = (item[key] ?? detail[key]).map({ String(describing: $0) }), !value.isEmpty { return value }
        }
        let duration = Int(Kit.number(window["duration"] ?? item["duration"] ?? detail["duration"]) ?? 0)
        let unit = String(describing: window["timeUnit"] ?? item["timeUnit"] ?? detail["timeUnit"] ?? "").uppercased()
        guard duration > 0 else { return "Limite \(index + 1)" }
        if unit.contains("MINUTE") { return duration == 300 ? "Sessione (5 ore)" : "\(duration) min" }
        if unit.contains("HOUR") { return "\(duration) ore" }
        if unit.contains("DAY") { return duration == 7 ? "Settimana" : "\(duration) giorni" }
        return "Limite \(duration)"
    }

    /// sessions/<workspace>/<session>/agents/<agent>/wire.jsonl: each usage.record is
    /// one billed request, each typed turn.prompt / turn.steer a prompt. A fork
    /// copies its source's records first, so copies count once.
    private static func localStats(_ sessions: URL) -> LocalStats? {
        struct Row { let usage: Bool; let key: String; let date: Date; let model: String?; let tokens: Int; let session: String }
        var wires: [(forked: Bool, rows: [Row])] = []
        for workspace in subdirectories(sessions) {
            for session in subdirectories(workspace) {
                for agent in subdirectories(session.appendingPathComponent("agents")) {
                    let wire = agent.appendingPathComponent("wire.jsonl")
                    guard recent(wire) else { continue }
                    var forked = false
                    var rows: [Row] = []
                    jsonLines(wire, markers: ["\"usage.record\"", "\"turn.prompt\"", "\"turn.steer\"", "\"forked\""]) { record in
                        let kind = record["type"] as? String
                        if kind == "forked" { forked = true; return }
                        guard let time = Kit.number(record["time"]), let date = Kit.date(time) else { return }
                        let agentID = String(describing: record["agentId"] ?? "")
                        if kind == "usage.record" {
                            let usage = object(record["usage"])
                            let parts = ["inputOther", "output", "inputCacheRead", "inputCacheCreation"].map { count(usage[$0]) }
                            guard let model = (record["model"] as? String)?.trimmingCharacters(in: .whitespaces),
                                  !model.isEmpty, parts.reduce(0, +) > 0 else { return }
                            rows.append(Row(usage: true, key: "\(agentID)|\(time)|\(model)|\(parts)", date: date,
                                            model: model, tokens: parts.reduce(0, +), session: session.lastPathComponent))
                        } else if kind == "turn.prompt" || kind == "turn.steer" {
                            let origin = object(record["origin"])
                            let originKind = origin["kind"] as? String
                            guard originKind == "user" || (["skill_activation", "plugin_command"].contains(originKind ?? "")
                                                           && origin["trigger"] as? String == "user-slash") else { return }
                            let id = record[kind == "turn.prompt" ? "promptId" : "messageId"] as? String
                            rows.append(Row(usage: false, key: "\(kind ?? "")|\(id ?? "\(agentID)|\(time)")", date: date,
                                            model: nil, tokens: 0, session: session.lastPathComponent))
                        }
                    }
                    wires.append((forked, rows))
                }
            }
        }
        var tally = StatsTally()
        var seen = Set<String>()
        for wire in wires.sorted(by: { !$0.forked && $1.forked }) {
            for row in wire.rows where seen.insert("\(row.usage)|\(row.key)").inserted {
                if row.usage {
                    tally.tokens(row.tokens, on: row.date, model: row.model, session: row.session)
                } else {
                    tally.prompt(on: row.date, session: row.session)
                }
            }
        }
        return tally.stats
    }
}

// MARK: Muse

/// Session and weekly percents from the Muse client's own key endpoint, asked
/// with the `muse login` token, which is only read. Pay-as-you-go accounts
/// have no subscription windows.
struct MuseCollector: UsageCollector {
    let id = "muse"
    let displayName = "Muse"
    let symbol = "paintpalette"

    private static let keyURL = URL(string: "https://api.meta.ai/muse-code/key")!

    func fetch(previous: AgentUsage?) -> AgentUsage? {
        let configDirs = Self.dirs(env: "XDG_CONFIG_HOME", fallback: ".config")
        let dataDirs = Kit.env("MUSE_DATA_DIR").map { [Kit.expand($0)] } ?? Self.dirs(env: "XDG_DATA_HOME", fallback: ".local/share")
        let authFiles = Kit.env("MUSE_AUTH_PATH").map { [Kit.expand($0)] } ?? configDirs.map { $0.appendingPathComponent("auth.json") }
        let token = authFiles.lazy.compactMap { file -> String? in
            let login = object(object(Kit.readJSON(file)?["providers"])["meta"])
            return (login["access_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }.first

        guard let token else {
            // Waiting for a sign-in only where the Muse CLI itself is set up.
            let installed = configDirs.contains(where: Kit.exists)
                || dataDirs.contains { Kit.exists($0.appendingPathComponent("sessions")) }
            return installed ? AgentUsage(note: "Accesso richiesto: esegui `muse login`") : nil
        }

        // The answer also carries a minted API key, which is never kept.
        let response = Kit.request(Self.keyURL, method: "POST", headers: ["Authorization": "Bearer \(token)",
                                                                          "Accept": "application/json"],
                                   json: [String: Any](), timeout: 10)
        guard response.ok, let payload = response.object else {
            let note = response.ok ? "Muse ha risposto in un formato non leggibile"
                : Kit.failureNote(response, provider: "Muse", signIn: "esegui `muse login`")
            return keptUsage(previous, note: note)
        }
        let tier = (payload["subs_tier_name"] as? String).flatMap { $0.isEmpty ? nil : Kit.capitalized($0) }
        guard let usage = payload["subs_usage"] as? [String: Any] else {
            if payload["is_subs_active"] as? Bool == false {
                return AgentUsage(note: "Pay-as-you-go: nessun limite di abbonamento", fetchedAt: Date())
            }
            if payload["is_subs_active"] as? Bool == true {
                return AgentUsage(plan: tier, fetchedAt: Date()) // a plan without windows
            }
            return keptUsage(previous, note: "Muse non ha restituito dati di utilizzo", plan: tier)
        }

        var limits: [UsageLimit] = []
        let window = object(usage["window"])
        if let used = Kit.number(window["used_percent"]) {
            let minutes = Int(Kit.number(window["window_duration_mins"]) ?? 0)
            let label = minutes >= 60 && minutes % 60 == 0 ? "Sessione (\(minutes / 60) ore)"
                : minutes > 0 ? "Sessione (\(minutes) min)" : "Sessione"
            limits.append(UsageLimit(label: label, percent: Kit.clamp(used / 100), resetsAt: looseDate(window["resets_at"])))
        }
        let weekly = object(usage["weekly"])
        if let used = Kit.number(weekly["used_percent"]) {
            limits.append(UsageLimit(label: "Settimana", percent: Kit.clamp(used / 100), resetsAt: looseDate(weekly["resets_at"])))
        }
        guard !limits.isEmpty else {
            return keptUsage(previous, note: "Muse non ha restituito limiti", plan: tier)
        }
        return AgentUsage(plan: tier, limits: limits, fetchedAt: Date())
    }

    /// `$XDG_…/muse` when set, else the Linux default and macOS Application Support.
    private static func dirs(env: String, fallback: String) -> [URL] {
        if let base = Kit.env(env) { return [Kit.expand(base).appendingPathComponent("muse")] }
        return [Kit.home.appendingPathComponent(fallback).appendingPathComponent("muse"),
                Kit.home.appendingPathComponent("Library/Application Support/muse")]
    }
}

// MARK: Antigravity

/// Plan and limits from Google's Cloud Code API (loadCodeAssist,
/// retrieveUserQuotaSummary), asked with whichever Antigravity sign-in is on
/// this Mac. Every store is only read; a lapsed token waits for its owner.
struct AntigravityCollector: UsageCollector {
    let id = "agy"
    let displayName = "Antigravity"
    let symbol = "arrow.up.circle"

    private static let defaultCloudCode = "https://daily-cloudcode-pa.googleapis.com"

    private struct Login {
        let source: String // the harness to open, for notes
        let token: String
        let expires: Date?
        let authMethod: String
        var fresh: Bool { !token.isEmpty && (expires.map { $0 > Date() } ?? true) }
    }

    func fetch(previous: AgentUsage?) -> AgentUsage? {
        let gemini = Kit.home.appendingPathComponent(".gemini")
        let roots = Kit.env("AGY_DIR").map { [Kit.expand($0)] }
            ?? ["antigravity-cli", "antigravity"].map { gemini.appendingPathComponent($0) }
        let installed = roots.contains(where: Kit.exists) || Kit.which("agy") != nil
        let logins = Self.logins(roots: roots, gemini: gemini, agyInstalled: installed)
        guard installed || !logins.isEmpty else { return nil }
        let stats = roots.lazy.compactMap(Self.localStats).first

        let agy = logins.first { $0.source == "agy" }
        let fallbackPlan: String? = switch agy?.authMethod {
        case "enterprise": "Enterprise"
        case "cloud", "vertex": "Cloud"
        default: nil
        }
        // The token refreshed most recently (latest expiry) goes first, unknown expiry after.
        let fresh = logins.filter(\.fresh).sorted { ($0.expires ?? .distantPast) > ($1.expires ?? .distantPast) }
        guard !fresh.isEmpty else {
            guard let lead = logins.first(where: { !$0.token.isEmpty }) else {
                return AgentUsage(plan: fallbackPlan, note: "Accesso richiesto: apri `agy` per accedere", stats: stats)
            }
            return keptUsage(previous, note: "Accesso scaduto: apri \(Self.name(lead.source)) per rinnovarlo",
                             plan: previous?.plan ?? fallbackPlan, stats: stats)
        }

        var refused: Login?
        for login in fresh {
            let assist = Self.post("loadCodeAssist", token: login.token, body: [:])
            if assist.status == 401 || assist.status == 403 { refused = refused ?? login; continue }
            guard assist.ok else {
                return keptUsage(previous, note: Kit.failureNote(assist, provider: "Google", signIn: ""), stats: stats)
            }
            let data = assist.object ?? [:]
            var body: [String: Any] = [:]
            let project = data["cloudaicompanionProject"]
            if let id = ((project as? [String: Any])?["id"] ?? project) as? String,
               !id.trimmingCharacters(in: .whitespaces).isEmpty {
                body["project"] = id.trimmingCharacters(in: .whitespaces)
            }
            let quota = Self.post("retrieveUserQuotaSummary", token: login.token, body: body)
            if quota.status == 401 || quota.status == 403 { refused = refused ?? login; continue }
            guard quota.ok, let limits = Self.limits(quota.object) else {
                let note = quota.ok ? "Google ha inviato una risposta non leggibile"
                    : Kit.failureNote(quota, provider: "Google", signIn: "")
                return keptUsage(previous, note: note, stats: stats)
            }
            return AgentUsage(plan: Self.tier(data) ?? fallbackPlan, limits: limits, stats: stats, fetchedAt: Date())
        }
        let source = Self.name(refused?.source ?? "agy")
        return keptUsage(previous, note: "Accesso rifiutato: apri \(source) per accedere di nuovo", stats: stats)
    }

    private static func name(_ source: String) -> String { source == "agy" ? "`agy`" : source }

    /// The endpoint stays on Google's HTTPS hosts; CLOUD_CODE_URL may only move it there.
    private static func post(_ method: String, token: String, body: [String: Any]) -> Kit.Response {
        var base = defaultCloudCode
        if let custom = Kit.env("CLOUD_CODE_URL"), let url = URL(string: custom), url.scheme == "https",
           let host = url.host?.lowercased(), host == "googleapis.com" || host.hasSuffix(".googleapis.com") {
            base = custom.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard let url = URL(string: "\(base)/v1internal:\(method)") else { return Kit.Response(status: 0, data: nil, headers: [:]) }
        return Kit.request(url, method: "POST", headers: ["Authorization": "Bearer \(token)", "User-Agent": "antigravity"],
                           json: body, timeout: 8)
    }

    // MARK: Sign-ins

    private static func logins(roots: [URL], gemini: URL, agyInstalled: Bool) -> [Login] {
        var logins: [Login] = []
        // agy keeps its sign-in in the keyring (go-keyring), else in a file of its own.
        var agyData: [String: Any]?
        if agyInstalled, let secret = Kit.keychain(service: "gemini", account: "antigravity") {
            agyData = decodeKeyring(secret)
        }
        if agyData == nil {
            let files = roots.map { $0.appendingPathComponent("antigravity-oauth-token") }
                + [gemini.appendingPathComponent("jetski-standalone-oauth-token")]
            agyData = files.lazy.compactMap(Kit.readJSON).first
        }
        if let data = agyData {
            let token = object(data["token"])
            logins.append(Login(source: "agy",
                                token: (token["access_token"] ?? data["access_token"]) as? String ?? "",
                                expires: looseDate(token["expiry"] ?? data["expiry"]),
                                authMethod: data["auth_method"] as? String ?? "consumer"))
        }

        // omp, pi and opencode's Antigravity plugin use the same Google client.
        let omp = Kit.home.appendingPathComponent(".omp/agent/agent.db")
        if Kit.exists(omp) {
            let rows = Kit.sqlite(omp, "SELECT data FROM auth_credentials WHERE provider = 'google-antigravity' "
                                  + "AND credential_type = 'oauth' AND disabled_cause IS NULL") ?? []
            for row in rows {
                guard let text = row["data"] as? String,
                      let data = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { continue }
                if let login = harnessLogin("omp", data) { logins.append(login) }
            }
        }
        let pi = Kit.env("PI_CODING_AGENT_DIR").map(Kit.expand) ?? Kit.home.appendingPathComponent(".pi/agent")
        if let login = harnessLogin("pi", Kit.readJSON(pi.appendingPathComponent("auth.json"))?["google-antigravity"]) {
            logins.append(login)
        }
        let config = Kit.env("XDG_CONFIG_HOME").map(Kit.expand) ?? Kit.home.appendingPathComponent(".config")
        let data = Kit.env("XDG_DATA_HOME").map(Kit.expand) ?? Kit.home.appendingPathComponent(".local/share")
        if Kit.exists(config.appendingPathComponent("opencode/antigravity-accounts.json")),
           let login = harnessLogin("opencode", Kit.readJSON(data.appendingPathComponent("opencode/auth.json"))?["google"]) {
            logins.append(login)
        }
        return logins
    }

    private static func decodeKeyring(_ secret: String) -> [String: Any]? {
        var data = Data(secret.utf8)
        if secret.hasPrefix("go-keyring-base64:") {
            guard let decoded = Data(base64Encoded: String(secret.dropFirst("go-keyring-base64:".count))) else { return nil }
            data = decoded
        } else if secret.hasPrefix("go-keyring-encoded:") {
            let hex = Array(secret.dropFirst("go-keyring-encoded:".count))
            guard hex.count % 2 == 0 else { return nil }
            data = Data(stride(from: 0, to: hex.count, by: 2).compactMap { UInt8(String(hex[$0...$0 + 1]), radix: 16) })
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func harnessLogin(_ source: String, _ value: Any?) -> Login? {
        guard let data = value as? [String: Any], (data["type"] as? String ?? "oauth") == "oauth",
              let access = data["access"] as? String, !access.isEmpty else { return nil }
        return Login(source: source, token: access, expires: looseDate(data["expires"]), authMethod: "consumer")
    }

    // MARK: Plan and limits

    private static func tier(_ data: [String: Any]) -> String? {
        for key in ["paidTier", "currentTier"] {
            let tier = object(data[key])
            let name = (tier["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let id = (tier["id"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty || !id.isEmpty else { continue }
            for word in ["ultra", "pro", "free"] where id.lowercased().contains(word) || name.lowercased().contains(word) {
                return Kit.capitalized(word)
            }
            if name.lowercased().hasPrefix("google ai ") { return String(name.dropFirst(10)).trimmingCharacters(in: .whitespaces) }
            return name.isEmpty ? Kit.capitalized(id.replacingOccurrences(of: "-tier", with: "")) : name
        }
        return nil
    }

    /// Share spent; proto3 leaves a zero remainder out, so a bucket with a
    /// reset and no remainder is fully spent.
    private static func used(_ bucket: [String: Any]) -> Double? {
        if bucket["disabled"] as? Bool == true { return nil }
        let remaining = bucket["remainingFraction"] ?? bucket["remaining_fraction"]
        let amount = bucket["remainingAmount"] ?? bucket["remaining_amount"]
        if remaining == nil, let amount { return Kit.number(amount) == 0 ? 1 : nil }
        if remaining == nil { return reset(bucket) != nil ? 1 : nil }
        return Kit.number(remaining).map { Kit.clamp(1 - $0) }
    }

    private static func reset(_ bucket: [String: Any]) -> Date? { looseDate(bucket["resetTime"] ?? bucket["reset_time"]) }

    /// Gemini's 5-hour and weekly buckets are the plan's limits; other groups
    /// (Claude/GPT) show once touched. nil is an unreadable answer.
    private static func limits(_ data: [String: Any]?) -> [UsageLimit]? {
        guard let data, data["error"] == nil else { return nil }
        if data["groups"] != nil && !(data["groups"] is [Any]) { return nil }
        if data["buckets"] != nil && !(data["buckets"] is [Any]) { return nil }
        var groups = (data["groups"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        if groups.isEmpty, let buckets = data["buckets"] as? [Any], !buckets.isEmpty {
            groups = [["displayName": "Gemini", "buckets": buckets]]
        }
        guard !groups.isEmpty else { return [] }
        let geminiIndex = groups.firstIndex { ($0["displayName"] as? String ?? "").lowercased().contains("gemini") } ?? 0

        var session: [String: Any]?, weekly: [String: Any]?
        for case let bucket as [String: Any] in groups[geminiIndex]["buckets"] as? [Any] ?? [] where used(bucket) != nil {
            let window = (bucket["window"] as? String ?? "").lowercased()
            let id = (bucket["bucketId"] as? String ?? "").lowercased()
            let name = (bucket["displayName"] as? String ?? "").lowercased()
            if window == "5h" || id.contains("5h") || name.contains("five") { session = bucket }
            else if window == "weekly" || id.contains("weekly") || name.contains("week") { weekly = bucket }
        }
        var limits: [UsageLimit] = []
        if let session { limits.append(UsageLimit(label: "Sessione (5 ore)", percent: used(session) ?? 0, resetsAt: reset(session))) }
        if let weekly { limits.append(UsageLimit(label: "Settimana", percent: used(weekly) ?? 0, resetsAt: reset(weekly))) }

        for (index, group) in groups.enumerated() where index != geminiIndex {
            let groupName = (group["displayName"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let short = groupName.lowercased().contains("claude") ? "Claude/GPT" : (groupName.isEmpty ? "Altri modelli" : groupName)
            for case let bucket as [String: Any] in group["buckets"] as? [Any] ?? [] {
                guard let spent = used(bucket), spent > 0 else { continue }
                let week = (bucket["window"] as? String ?? "").lowercased().contains("week")
                limits.append(UsageLimit(label: "\(short) · \(week ? "settimana" : "sessione")", percent: spent, resetsAt: reset(bucket)))
            }
        }
        return limits
    }

    // MARK: Local stats

    /// agy's history.jsonl prompts and the tokens each transcript step reports.
    private static func localStats(_ root: URL) -> LocalStats? {
        let history = root.appendingPathComponent("history.jsonl")
        let brain = root.appendingPathComponent("brain")
        guard Kit.exists(history) || Kit.exists(brain) else { return nil }
        var tally = StatsTally()
        if recent(history) {
            jsonLines(history, markers: []) { entry in
                let conversation = (entry["conversationId"] ?? entry["conversation_id"] ?? entry["sessionId"]) as? String
                tally.prompt(on: looseDate(entry["timestamp"]), session: conversation)
            }
        }
        for conversation in subdirectories(brain) {
            let transcript = conversation.appendingPathComponent(".system_generated/logs/transcript.jsonl")
            guard recent(transcript) else { continue }
            var model = ""
            jsonLines(transcript, markers: []) { step in
                model = stepModel(step) ?? model
                guard let tokens = stepTokens(step), tokens > 0 else { return }
                tally.tokens(tokens, on: looseDate(step["created_at"] ?? step["timestamp"]),
                             model: model.isEmpty ? nil : model, session: conversation.lastPathComponent)
            }
        }
        return tally.stats
    }

    private static func stepModel(_ step: [String: Any]) -> String? {
        for field in ["model", "model_name", "model_id"] {
            if let value = step[field] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty { return modelKey(value) }
        }
        guard let content = step["content"] as? String, content.contains("Model Selection"),
              let match = content.range(of: #"Model Selection` (?:from .+? )?to (.+?)\.(?:\s|$|<)"#, options: .regularExpression)
        else { return nil }
        let text = String(content[match])
        guard let to = text.range(of: " to ", options: .backwards) else { return nil }
        return modelKey(String(text[to.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ". <\n")))
    }

    private static func modelKey(_ name: String) -> String {
        name.replacingOccurrences(of: "[()]", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "[\\s_]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
    }

    /// Gemini's nested counts (prompt includes cache, thoughts beside the
    /// candidates) or the newer flat input/output/cache counts.
    private static func stepTokens(_ step: [String: Any]) -> Int? {
        for source in [step["usage"] as? [String: Any], step].compactMap({ $0 }) {
            if source["prompt_token_count"] != nil || source["candidates_token_count"] != nil {
                return count(source["prompt_token_count"]) + count(source["candidates_token_count"])
                    + count(source["thoughts_token_count"])
            }
            let keys = ["input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"]
            if keys.contains(where: { source[$0] != nil }) { return keys.map { count(source[$0]) }.reduce(0, +) }
        }
        return nil
    }
}
