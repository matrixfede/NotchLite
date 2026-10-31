// Cursor, Grok Bot, GitHub Copilot and Devin collectors, ported from Omarchy's (MIT, basecamp/omarchy).

import Foundation

// MARK: Shared bits

/// A failed check keeps the last good answer, with a note saying why.
fileprivate func keptUsage(_ previous: AgentUsage?, note: String) -> AgentUsage {
    var usage = previous ?? AgentUsage()
    usage.note = note
    return usage
}

/// JWT claims, read without checking the signature (only to tell when it lapses).
fileprivate func jwtClaims(_ token: String) -> [String: Any] {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { return [:] }
    var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload),
          let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return claims
}

fileprivate func tokenLapsed(_ token: String) -> Bool {
    guard let expires = Kit.number(jwtClaims(token)["exp"]), expires > 0 else { return false }
    return expires <= Date().timeIntervalSince1970
}

/// ISO 8601, epoch seconds / milliseconds, or a plain "yyyy-MM-dd[ HH:mm:ss]" read as UTC.
fileprivate func flexibleDate(_ value: Any?) -> Date? {
    if let date = Kit.date(value) { return date }
    guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    for format in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: text) { return date }
    }
    return nil
}

/// Today's and this week's (last 7 local days) token counts, built row by row.
fileprivate struct WeekTally {
    let today = Calendar.current.startOfDay(for: Date())
    var weekStart: Date { Calendar.current.date(byAdding: .day, value: -6, to: today) ?? today }
    var stats = LocalStats()
    var models: [String: Int] = [:]
    var sessionsToday = Set<String>()

    func isToday(_ date: Date) -> Bool { date >= today }
    func inWeek(_ date: Date) -> Bool { date >= weekStart }

    mutating func add(tokens: Int, model: String, at date: Date) {
        guard inWeek(date), tokens > 0 else { return }
        stats.tokensWeek += tokens
        models[model, default: 0] += tokens
        if isToday(date) { stats.tokensToday += tokens }
    }

    mutating func addPrompt(session: String, at date: Date) {
        guard isToday(date) else { return }
        stats.promptsToday += 1
        sessionsToday.insert(session)
    }

    var result: LocalStats? {
        var stats = stats
        stats.sessionsToday = max(stats.sessionsToday, sessionsToday.count)
        stats.topModel = models.max { $0.value < $1.value }?.key
        return stats.isEmpty ? nil : stats
    }
}

fileprivate func tableColumns(_ db: URL, _ table: String) -> Set<String> {
    Set((Kit.sqlite(db, "PRAGMA table_info(\(table))") ?? []).compactMap { $0["name"] as? String })
}

// MARK: Cursor sign-in (shared by Cursor and Grok Bot)

fileprivate enum CursorAuth {
    static let host = "https://api2.cursor.sh/aiserver.v1.DashboardService/"
    static let signIn = "accedi a Cursor o esegui `cursor-agent login`"
    static let lapsedNote = "Token di Cursor scaduto: apri Cursor o esegui `cursor-agent` per rinnovarlo"

    static var cliAuthFiles: [URL] {
        var files: [URL] = []
        if let path = Kit.env("CURSOR_AUTH_PATH") { files.append(Kit.expand(path)) }
        if let xdg = Kit.env("XDG_CONFIG_HOME") { files.append(Kit.expand(xdg).appendingPathComponent("cursor/auth.json")) }
        files.append(Kit.home.appendingPathComponent(".config/cursor/auth.json"))
        files.append(Kit.home.appendingPathComponent("Library/Application Support/cursor/auth.json"))
        return files
    }

    static var stateDatabases: [URL] {
        [Kit.home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb"),
         Kit.home.appendingPathComponent(".config/Cursor/User/globalStorage/state.vscdb")]
    }

    /// Cursor is used here: CLI or editor installed, or their config dirs exist.
    static var inUse: Bool {
        let dirs = [".cursor", ".config/cursor", "Library/Application Support/Cursor"].map { Kit.home.appendingPathComponent($0) }
        return dirs.contains(where: Kit.exists) || Kit.which("cursor-agent") != nil
            || Kit.exists(URL(fileURLWithPath: "/Applications/Cursor.app"))
    }

    /// Exported token, the CLI's auth.json, the editor's state.vscdb, then the
    /// CLI's Keychain item. The first that hasn't lapsed wins, else the first.
    static func token() -> String? {
        if let bearer = Kit.env("CURSOR_AUTH_TOKEN") { return bearer }
        let auth = cliAuthFiles.lazy.compactMap(Kit.readJSON).first
        let traded = (auth?["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key = Kit.env("CURSOR_API_KEY") {
            // Only the token the CLI traded for this key stands for it; the key itself is never sent.
            return (auth?["apiKey"] as? String) == key ? traded : nil
        }
        let sources: [() -> String?] = [
            { traded },
            { stateDatabases.lazy.compactMap(editorToken).first },
            { Kit.keychain(service: "cursor-access-token", account: "cursor-user") },
        ]
        var first: String?
        for source in sources {
            guard let token = source(), !token.isEmpty else { continue }
            if !tokenLapsed(token) { return token }
            first = first ?? token
        }
        return first
    }

    private static func editorToken(_ db: URL) -> String? {
        guard Kit.exists(db),
              let row = Kit.sqlite(db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1")?.first
        else { return nil }
        let value = (row["value"] as? String) ?? (row["value"] as? Data).flatMap { String(data: $0, encoding: .utf8) }
        return value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One Connect (JSON) RPC on Cursor's dashboard service.
    static func call(_ method: String, token: String, body: [String: Any] = [:]) -> Kit.Response {
        Kit.request(URL(string: host + method)!, method: "POST", headers: [
            "Connect-Protocol-Version": "1",
            "Authorization": "Bearer \(token)",
            "x-cursor-client-type": "cli",
        ], json: body, timeout: 15)
    }
}

// MARK: Cursor

struct CursorCollector: UsageCollector {
    let id = "cursor"
    let displayName = "Cursor"
    let symbol = "cursorarrow.rays"

    func fetch(previous: AgentUsage?) -> AgentUsage? {
        guard let token = CursorAuth.token() else {
            return CursorAuth.inUse ? AgentUsage(note: "Accedi con `cursor-agent login` o dall'editor Cursor per vedere i limiti") : nil
        }
        if tokenLapsed(token) { return keptUsage(previous, note: CursorAuth.lapsedNote) }

        let period = CursorAuth.call("GetCurrentPeriodUsage", token: token)
        guard period.ok, let periodBody = period.object else {
            let note = period.ok ? "Risposta di Cursor non leggibile"
                : Kit.failureNote(period, provider: "Cursor", signIn: CursorAuth.signIn)
            return keptUsage(previous, note: note)
        }
        let planResponse = CursorAuth.call("GetPlanInfo", token: token)
        let planInfo = planResponse.ok ? planResponse.object?["planInfo"] as? [String: Any] ?? [:] : nil

        var usage = AgentUsage(fetchedAt: Date())
        if let name = planInfo?["planName"] as? String, !name.isEmpty {
            usage.plan = Kit.capitalized(name)
        } else if planInfo == nil {
            usage.plan = previous?.plan
        }
        usage.limits = limits(periodBody, planInfo: planInfo)
        usage.stats = weekStats(token: token) ?? previous?.stats
        return usage
    }

    /// Cursor's own percentages; spend is never divided into the allowance.
    private func limits(_ period: [String: Any], planInfo: [String: Any]?) -> [UsageLimit] {
        let plan = period["planUsage"] as? [String: Any] ?? [:]
        let spend = period["spendLimitUsage"] as? [String: Any] ?? [:]
        let cycleEnd = period["billingCycleEnd"]
        var window = "mese", includedReset: Any? = cycleEnd
        if Self.weeklyIncluded(planInfo) {
            window = "settimana"
            if let stamp = Kit.number(planInfo?["includedUsageResetsAt"]), stamp > 0 {
                includedReset = stamp < 100_000_000_000 ? stamp : stamp / 1000
            } else {
                includedReset = nil
            }
        }
        var limits: [UsageLimit] = []
        for (label, key) in [(Kit.capitalized(window), "totalPercentUsed"),
                             ("Modelli Auto (\(window))", "autoPercentUsed"),
                             ("Modelli scelti (\(window))", "apiPercentUsed")] where plan[key] != nil {
            limits.append(Kit.limit(label, used: (Kit.number(plan[key]) ?? 0) / 100, resetsAt: includedReset))
        }
        if let limitCents = Kit.number(spend["individualLimit"]), limitCents > 0 {
            let used = Kit.number(spend["individualUsed"]) ?? 0
            let label = "On-demand \(Kit.money(used / 100)) / \(Kit.money(limitCents / 100))"
            limits.append(Kit.limit(label, used: used / limitCents, resetsAt: cycleEnd))
        }
        return limits
    }

    private static func weeklyIncluded(_ plan: [String: Any]?) -> Bool {
        switch plan?["includedUsagePeriod"] {
        case let text as String: ["WEEKLY", "INCLUDED_USAGE_PERIOD_WEEKLY", "2"].contains(text.uppercased())
        case let value: Kit.number(value) == 2
        }
    }

    /// Tokens by model: one aggregation for today, one for the last 7 days.
    private func weekStats(token: String) -> LocalStats? {
        var tally = WeekTally()
        let now = Int(Date().timeIntervalSince1970 * 1000)
        func aggregate(from start: Date) -> [String: Int]? {
            let response = CursorAuth.call("GetAggregatedUsageEvents", token: token, body: [
                "startDate": String(Int(start.timeIntervalSince1970 * 1000)), "endDate": String(now),
            ])
            guard response.ok, let object = response.object else { return nil }
            let rows = object["aggregations"] as? [[String: Any]] ?? []
            var byModel: [String: Int] = [:]
            for row in rows {
                let tokens = ["inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens"]
                    .reduce(0) { $0 + Int(Kit.number(row[$1]) ?? 0) }
                byModel[(row["modelIntent"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "cursor", default: 0] += tokens
            }
            return byModel
        }
        guard let week = aggregate(from: tally.weekStart), let today = aggregate(from: tally.today) else { return nil }
        for (model, tokens) in week { tally.add(tokens: tokens, model: model, at: tally.weekStart) }
        tally.stats.tokensToday = today.values.reduce(0, +)
        // Cursor's dashboard counts usage events, not prompts or sessions.
        return tally.result
    }
}

// MARK: Grok Bot

struct GrokBotCollector: UsageCollector {
    let id = "grokbot"
    let displayName = "Grok Bot"
    let symbol = "sparkles"

    func fetch(previous: AgentUsage?) -> AgentUsage? {
        // Without a Cursor sign-in there's no telling whether Grok Bot is used: stay hidden.
        guard let token = CursorAuth.token() else { return nil }
        let hasKept = !(previous?.limits.isEmpty ?? true)
        if tokenLapsed(token) { return hasKept ? keptUsage(previous, note: CursorAuth.lapsedNote) : nil }

        let response = CursorAuth.call("GetSandUsageStatus", token: token)
        guard response.ok, let status = response.object else {
            guard hasKept else { return nil }
            let note = response.ok ? "Risposta di Cursor non leggibile"
                : Kit.failureNote(response, provider: "Cursor", signIn: CursorAuth.signIn + " con l'account di Grok Bot")
            return keptUsage(previous, note: note)
        }
        // Protobuf JSON leaves out false: no included limit means no Grok Bot on this account.
        guard status["hasNonZeroIncludedLimit"] as? Bool == true else { return nil }
        let plan = (status["grokPlanLabel"] as? String).flatMap { $0.isEmpty ? nil : Kit.capitalized($0) }
        let percent = (Kit.number(status["usagePercent"]) ?? 0) / 100
        return AgentUsage(plan: plan,
                          limits: [Kit.limit("Settimana", used: percent, resetsAt: status["nextResetTimestampUtc"])],
                          fetchedAt: Date())
    }
}

// MARK: GitHub Copilot

struct CopilotCollector: UsageCollector {
    let id = "copilot"
    let displayName = "GitHub Copilot"
    let symbol = "airplane"

    private static let planNames = ["individual": "Pro", "individual_pro": "Pro+", "business": "Business",
                                    "enterprise": "Enterprise", "free": "Free", "max": "Max"]

    func fetch(previous: AgentUsage?) -> AgentUsage? {
        let home = Kit.env("COPILOT_HOME").map(Kit.expand) ?? Kit.home.appendingPathComponent(".copilot")
        // The quota probe hands a GitHub token to GitHub, so only where the Copilot CLI is used.
        guard Kit.exists(home) else { return nil }
        let stats = localStats(home.appendingPathComponent("session-store.db"))

        guard let token = githubToken() else {
            var usage = AgentUsage(note: "Accedi con `gh auth login` per vedere i crediti di Copilot")
            usage.stats = stats
            return usage
        }
        let response = Kit.request(URL(string: "https://api.github.com/copilot_internal/user")!, headers: [
            "Authorization": "Bearer \(token)", "Accept": "application/json",
        ], timeout: 8)
        var usage: AgentUsage
        if let payload = response.object, response.ok {
            usage = quota(payload) ?? keptUsage(previous, note: "GitHub non ha indicato i crediti di Copilot")
        } else {
            usage = keptUsage(previous, note: Kit.failureNote(response, provider: "GitHub", signIn: "esegui `gh auth login`"))
        }
        usage.stats = stats ?? usage.stats
        return usage
    }

    /// Exported token, else `gh`'s own (kept in the Keychain on macOS).
    private func githubToken() -> String? {
        for name in ["COPILOT_QUOTA_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"] { if let token = Kit.env(name) { return token } }
        guard let gh = Kit.which("gh"),
              // --hostname: an Enterprise token must never go to api.github.com.
              let data = Kit.run(gh, ["auth", "token", "--hostname", "github.com"], timeout: 6),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    /// The account-wide AI credit allowance (premium_interactions snapshot).
    private func quota(_ payload: [String: Any]) -> AgentUsage? {
        guard let snapshot = (payload["quota_snapshots"] as? [String: Any])?["premium_interactions"] as? [String: Any]
        else { return nil }
        let rawPlan = ((payload["copilot_plan"] as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        var usage = AgentUsage(plan: rawPlan.isEmpty ? nil : Self.planNames[rawPlan] ?? Kit.capitalized(rawPlan),
                               fetchedAt: Date())
        if snapshot["unlimited"] as? Bool == true {
            usage.extra = "Crediti AI illimitati"
            return usage
        }
        guard let entitlement = Kit.number(snapshot["entitlement"]), entitlement > 0 else { return nil }
        var used = Kit.number(snapshot["credits_used"])
        if used == nil {
            if let remaining = Kit.number(snapshot["remaining"]) ?? Kit.number(snapshot["quota_remaining"]) {
                used = max(0, entitlement - remaining)
            } else if let percentLeft = Kit.number(snapshot["percent_remaining"]) {
                used = entitlement * max(0, 100 - percentLeft) / 100
            }
        }
        guard let used else { return nil }
        let reset = flexibleDate(payload["quota_reset_date_utc"]).flatMap { $0 > Date() ? $0 : nil }
        usage.limits = [UsageLimit(label: "Crediti AI (mese)", percent: Kit.clamp(used / entitlement), resetsAt: reset)]
        usage.extra = "\(Int(used.rounded())) di \(Int(entitlement.rounded())) crediti usati"
        return usage
    }

    /// The CLI session store's billed requests (assistant_usage_events), read-only.
    private func localStats(_ db: URL) -> LocalStats? {
        guard Kit.exists(db) else { return nil }
        let columns = tableColumns(db, "assistant_usage_events")
        let base = ["session_id", "model", "created_at", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"]
        guard Set(base).isSubset(of: columns) else { return nil }
        let optional = ["initiator", "agent_id", "copilot_usage_model", "total_nano_aiu"].filter(columns.contains)
        let sql = "SELECT \((base + optional).joined(separator: ", ")) FROM assistant_usage_events ORDER BY rowid DESC LIMIT 100000"
        guard let rows = Kit.sqlite(db, sql) else { return nil }

        var tally = WeekTally()
        for row in rows {
            guard let date = flexibleDate(row["created_at"]) else { continue }
            if !tally.inWeek(date) { continue }
            // A request to a custom provider (BYOK) carries no GitHub usage report: not Copilot's.
            if optional.contains("copilot_usage_model"), row["copilot_usage_model"] == nil, row["total_nano_aiu"] == nil { continue }
            let read = Int(Kit.number(row["cache_read_tokens"]) ?? 0), write = Int(Kit.number(row["cache_write_tokens"]) ?? 0)
            let input = Int(Kit.number(row["input_tokens"]) ?? 0), output = Int(Kit.number(row["output_tokens"]) ?? 0)
            let model = (row["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "copilot"
            tally.add(tokens: max(input, read + write) + output, model: model, at: date)
            let session = row["session_id"] as? String ?? "unknown"
            if tally.isToday(date) { tally.sessionsToday.insert(session) }
            // Only a current store says which requests a typed prompt started.
            if optional.contains("initiator"), row["initiator"] as? String == "user",
               ((row["agent_id"] as? String) ?? "").isEmpty {
                tally.addPrompt(session: session, at: date)
            }
        }
        return tally.result
    }
}

// MARK: Devin

struct DevinCollector: UsageCollector {
    let id = "devin"
    let displayName = "Devin"
    let symbol = "wand.and.stars"

    private static let staleAfter: TimeInterval = 900
    private static let tiers: [Int: String] = [
        1: "Teams", 2: "Pro", 3: "Enterprise Saas", 4: "Hybrid", 5: "Enterprise Self Hosted",
        6: "Waitlist Pro", 7: "Teams Ultimate", 8: "Pro Ultimate", 9: "Trial", 10: "Enterprise Self Serve",
        11: "Enterprise Saas Pooled", 12: "Devin Enterprise", 14: "Devin Teams", 15: "Devin Teams V2", 16: "Devin Pro",
        17: "Devin Max", 18: "Max", 19: "Devin Free", 20: "Devin Trial",
    ]

    private var dataDirs: [URL] {
        var dirs: [URL] = []
        if let dir = Kit.env("DEVIN_DATA_DIR") { dirs.append(Kit.expand(dir)) }
        if let xdg = Kit.env("XDG_DATA_HOME") { dirs.append(Kit.expand(xdg).appendingPathComponent("devin/cli")) }
        dirs += [".local/share/devin/cli", "Library/Application Support/devin/cli"].map { Kit.home.appendingPathComponent($0) }
        return dirs
    }

    private var cacheDirs: [URL] {
        var dirs: [URL] = []
        if let dir = Kit.env("DEVIN_CACHE_DIR") { dirs.append(Kit.expand(dir)) }
        if let xdg = Kit.env("XDG_CACHE_HOME") { dirs.append(Kit.expand(xdg).appendingPathComponent("devin/cli")) }
        dirs += [".cache/devin/cli", "Library/Caches/devin/cli"].map { Kit.home.appendingPathComponent($0) }
        return dirs
    }

    func fetch(previous: AgentUsage?) -> AgentUsage? {
        let credentials = dataDirs.map { $0.deletingLastPathComponent().appendingPathComponent("credentials.toml") }.first(where: Kit.exists)
        let database = dataDirs.map { $0.appendingPathComponent("sessions.db") }.first(where: Kit.exists)
        let quota = readQuota(signedInAt: credentials.flatMap(Kit.modified))
        let stats = database.flatMap(localStats)
        guard credentials != nil || database != nil || quota != nil || cacheDirs.contains(where: Kit.exists)
                || Kit.which("devin") != nil else { return nil }

        var usage = quota ?? AgentUsage()
        usage.stats = stats
        if quota == nil {
            usage.note = credentials != nil
                ? "Devin non ha ancora salvato la quota: avvialo per aggiornarla"
                : "Accedi con `devin auth login` per vedere i limiti"
        }
        return usage
    }

    /// The newest GetUserStatus answer the CLI cached since the last sign-in; no network call.
    private func readQuota(signedInAt: Date?) -> AgentUsage? {
        let cutoff = signedInAt.map { $0.timeIntervalSince1970 - 30 }
        var best: (fetched: Double, usage: AgentUsage)?
        for dir in cacheDirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("user_status.") && file.pathExtension == "bin" {
                guard let cache = Kit.readJSON(file), let encoded = cache["payload"] as? String,
                      var fetched = Kit.number(cache["fetched_at_secs"]), fetched > 0 else { continue }
                if fetched > 100_000_000_000 { fetched /= 1000 }
                if let cutoff, fetched < cutoff { continue }
                guard let payload = Data(base64Encoded: encoded), let usage = parseUserStatus([UInt8](payload)),
                      fetched > (best?.fetched ?? 0) else { continue }
                best = (fetched, usage)
            }
        }
        guard var usage = best?.usage, let fetched = best?.fetched else { return nil }
        let fetchedAt = Date(timeIntervalSince1970: fetched)
        usage.fetchedAt = fetchedAt
        // A window that reset since reads zero, its next reset unknown.
        usage.limits = usage.limits.map { limit in
            guard let reset = limit.resetsAt, reset <= Date() else { return limit }
            return UsageLimit(label: limit.label, percent: 0, resetsAt: nil)
        }
        let age = Date().timeIntervalSince(fetchedAt)
        if age >= Self.staleAfter || age < 0 {
            usage.note = "Dati di \(max(1, Int(age / 60))) min fa: avvia Devin per aggiornarli"
        }
        return usage
    }

    // UserStatus: field 10 plan tier, 13 PlanStatus. PlanStatus: 1 PlanInfo, 3 plan end,
    // 5-7 credits used, 14/15 daily/weekly percent left, 17/18 their resets.
    private func parseUserStatus(_ payload: [UInt8]) -> AgentUsage? {
        let status = ProtoFields(payload)
        let planStatus = status.message(13)
        let plan = planStatus.message(1)
        let tier = plan.text(2) ?? plan.varint(1).flatMap { Self.tiers[$0] } ?? status.varint(10).flatMap { Self.tiers[$0] }

        var limits: [UsageLimit] = []
        if !planStatus.isEmpty {
            let quotaPlan = plan.varint(35) == 2
            for (label, hidden, remaining, reset) in [("Giorno", 36, 14, 17), ("Settimana", 37, 15, 18)] {
                if (plan.varint(hidden) ?? 0) != 0 { continue }
                let resetAt = planStatus.varint(reset) ?? 0
                guard resetAt > 0 || quotaPlan else { continue }
                // Percent left, and proto3 leaves a zero off the wire.
                let left = Double(min(100, max(0, planStatus.varint(remaining) ?? 0)))
                limits.append(Kit.limit(label, used: (100 - left) / 100, resetsAt: resetAt > 0 ? resetAt : nil))
            }
            let planEnd = planStatus.message(3).varint(1)
            for (label, limitField, usedField) in [("Crediti prompt", 12, 6), ("Crediti flow", 13, 5), ("Crediti flex", 14, 7)] {
                let limit = plan.varint(limitField) ?? 0
                guard limit > 0 else { continue }
                let used = max(0, planStatus.varint(usedField) ?? 0)
                limits.append(Kit.limit(label, used: Double(used) / Double(limit), resetsAt: planEnd))
            }
        }
        guard tier != nil || !limits.isEmpty else { return nil }
        return AgentUsage(plan: tier, limits: limits)
    }

    /// Tokens from each assistant message's metrics, prompts from prompt_history (read-only).
    private func localStats(_ db: URL) -> LocalStats? {
        var tally = WeekTally()
        if tableColumns(db, "message_nodes").isSuperset(of: ["session_id", "created_at", "chat_message"]) {
            let sql = """
                SELECT created_at,
                  json_extract(chat_message, '$.metadata.generation_model') AS model,
                  coalesce(json_extract(chat_message, '$.metadata.metrics.input_tokens'), 0)
                  + coalesce(json_extract(chat_message, '$.metadata.metrics.output_tokens'), 0)
                  + coalesce(json_extract(chat_message, '$.metadata.metrics.cache_read_tokens'), 0)
                  + coalesce(json_extract(chat_message, '$.metadata.metrics.cache_creation_tokens'), 0) AS tokens
                FROM message_nodes
                WHERE chat_message LIKE '%"metrics"%' AND json_valid(chat_message)
                ORDER BY rowid DESC LIMIT 50000
                """
            for row in Kit.sqlite(db, sql) ?? [] {
                guard let date = flexibleDate(row["created_at"]) else { continue }
                let model = (row["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "devin"
                tally.add(tokens: Int(Kit.number(row["tokens"]) ?? 0), model: model, at: date)
            }
        }
        if tableColumns(db, "prompt_history").isSuperset(of: ["session_id", "timestamp"]) {
            for row in Kit.sqlite(db, "SELECT session_id, timestamp FROM prompt_history ORDER BY rowid DESC LIMIT 20000") ?? [] {
                guard let date = flexibleDate(row["timestamp"]) else { continue }
                tally.addPrompt(session: row["session_id"].map { "\($0)" } ?? "", at: date)
            }
        }
        return tally.result
    }
}

/// Field number -> first value of a protobuf message: Int for a varint, bytes for a length-delimited field.
fileprivate struct ProtoFields {
    private var fields: [Int: Any] = [:]
    var isEmpty: Bool { fields.isEmpty }

    init(_ data: [UInt8]) {
        var pos = 0
        func readVarint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while pos < data.count, shift <= 63 {
                let byte = data[pos]
                pos += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while pos < data.count {
            guard let tag = readVarint() else { break }
            let number = Int(tag >> 3)
            var value: Any?
            switch tag & 0x07 {
            case 0: guard let v = readVarint() else { return }; value = Int(bitPattern: UInt(v))
            case 1: pos += 8
            case 2:
                guard let length = readVarint(), length <= UInt64(data.count - pos) else { return }
                value = Array(data[pos..<pos + Int(length)])
                pos += Int(length)
            case 5: pos += 4
            default: return
            }
            if let value, fields[number] == nil { fields[number] = value }
        }
    }

    func message(_ number: Int) -> ProtoFields { ProtoFields(fields[number] as? [UInt8] ?? []) }
    func varint(_ number: Int) -> Int? { fields[number] as? Int }
    func text(_ number: Int) -> String? {
        guard let bytes = fields[number] as? [UInt8] else { return nil }
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
