// Z.ai, MiniMax, Synthetic, Ollama Cloud and OpenCode collectors, ported from Omarchy's (MIT, basecamp/omarchy).

import Foundation

// MARK: Shared credentials and local stats

private enum PlanAuth {
    static var dataHomes: [URL] {
        var homes = [Kit.home.appendingPathComponent(".local/share"),
                     Kit.home.appendingPathComponent("Library/Application Support")]
        if let xdg = Kit.env("XDG_DATA_HOME") { homes.insert(Kit.expand(xdg), at: 0) }
        return homes
    }

    static var openCodeAuth: [URL] { dataHomes.map { $0.appendingPathComponent("opencode/auth.json") } }
    static var piDir: URL { Kit.env("PI_CODING_AGENT_DIR").map(Kit.expand) ?? Kit.home.appendingPathComponent(".pi/agent") }
    static var ompDir: URL { Kit.home.appendingPathComponent(".omp/agent") }
    static var piAuth: URL { piDir.appendingPathComponent("auth.json") }
    static var ompAuth: URL { ompDir.appendingPathComponent("auth.json") }

    /// `~/.config/notchlite/agents/<id>.json` (NotchLite's twin of Omarchy's agent config).
    static func config(_ id: String) -> [String: Any] {
        var dirs = [Kit.home.appendingPathComponent(".config")]
        if let xdg = Kit.env("XDG_CONFIG_HOME") { dirs.insert(Kit.expand(xdg), at: 0) }
        for dir in dirs {
            if let json = Kit.readJSON(dir.appendingPathComponent("notchlite/agents/\(id).json")) { return json }
        }
        return [:]
    }

    static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// A stored key as pi resolves it: `!command` is never run, `$VAR` / `${VAR}` come from the environment.
    static func resolve(_ raw: String?) -> String? {
        guard let raw = string(raw), !raw.hasPrefix("!") else { return nil }
        guard raw.contains("$") else { return raw }
        let regex = try? NSRegularExpression(pattern: #"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))"#)
        var result = "", cursor = raw.startIndex
        for match in regex?.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) ?? [] {
            guard let whole = Range(match.range, in: raw) else { continue }
            let nameRange = Range(match.range(at: 1), in: raw) ?? Range(match.range(at: 2), in: raw)
            guard let nameRange, let value = Kit.env(String(raw[nameRange])) else { return nil }
            result += String(raw[cursor..<whole.lowerBound]) + value
            cursor = whole.upperBound
        }
        return string(result + String(raw[cursor...]))
    }

    /// First literal key `file` holds for one of `providers` (opencode, pi and omp share the shape).
    static func key(in file: URL, providers: [String]) -> (key: String, provider: String)? {
        guard let json = Kit.readJSON(file) else { return nil }
        for provider in providers {
            let entry = json[provider]
            let raw = (entry as? String) ?? (entry as? [String: Any]).flatMap {
                string($0["key"]) ?? string($0["apiKey"]) ?? string($0["token"])
            }
            if let key = resolve(raw) { return (key, provider) }
        }
        return nil
    }

    static func key(in files: [URL], providers: [String]) -> (key: String, provider: String)? {
        for file in files { if let found = key(in: file, providers: providers) { return found } }
        return nil
    }

    /// `KEY=value` lines of a dotenv file.
    static func dotenv(_ file: URL) -> [String: String] {
        var values: [String: String] = [:]
        for line in (Kit.readText(file) ?? "").split(whereSeparator: \.isNewline) {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("export ") { text = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard !text.hasPrefix("#"), let eq = text.firstIndex(of: "=") else { continue }
            let value = text[text.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if !value.isEmpty { values[text[..<eq].trimmingCharacters(in: .whitespaces)] = value }
        }
        return values
    }

    /// Only HTTPS to the provider's own domain(s) may carry its key.
    static func official(_ text: String?, domains: [String]) -> URL? {
        guard let text, let parts = URLComponents(string: text), parts.scheme == "https", parts.user == nil,
              let host = parts.host?.lowercased(),
              domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return URL(string: "https://\(host)")
    }
}

private enum PlanLocal {
    /// The database opencode itself reads (`OPENCODE_DB`, else opencode.db, else a V2 build's opencode-v2.db).
    static var openCodeDB: URL? {
        let roots = PlanAuth.dataHomes.map { $0.appendingPathComponent("opencode") }
        if let configured = Kit.env("OPENCODE_DB") {
            if configured.hasPrefix("/") || configured.hasPrefix("~") { return Kit.expand(configured) }
            return roots.map { $0.appendingPathComponent(configured) }.first(where: Kit.exists)
        }
        for root in roots {
            for name in ["opencode.db", "opencode-v2.db"] where Kit.exists(root.appendingPathComponent(name)) {
                return root.appendingPathComponent(name)
            }
        }
        return nil
    }

    private static let tokens = ["input", "output", "reasoning", "cache.read", "cache.write"]
        .map { "IFNULL(json_extract(data, '$.tokens.\($0)'), 0)" }.joined(separator: " + ")

    /// Last-7-days opencode stats for its own provider ids (both message stores), and whether
    /// opencode ever ran on them here.
    static func openCode(providers: [String], accept: (String, String) -> Bool = { _, _ in true },
                         model: (String) -> String) -> (stats: LocalStats?, used: Bool) {
        guard let db = openCodeDB, Kit.exists(db), !providers.isEmpty else { return (nil, false) }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let since = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let marks = providers.map { _ in "?" }.joined(separator: ",")
        let params: [Any] = providers.map { $0 as Any } + [Int(since.timeIntervalSince1970 * 1000)]
        let v2 = """
            SELECT id, session_id AS s, NULL AS parent,
              COALESCE(json_extract(data, '$.providerID'), json_extract(data, '$.model.providerID')) AS p,
              COALESCE(json_extract(data, '$.modelID'), json_extract(data, '$.model.id'), json_extract(data, '$.model.modelID')) AS m,
              json_extract(data, '$.time.created') AS t, \(tokens) AS tk
            FROM session_message WHERE type IN ('assistant', 'compaction') AND json_valid(data) AND p IN (\(marks)) AND t >= ?
            """
        let v1 = """
            SELECT id, session_id AS s, json_extract(data, '$.parentID') AS parent,
              json_extract(data, '$.providerID') AS p, json_extract(data, '$.modelID') AS m,
              json_extract(data, '$.time.created') AS t, \(tokens) AS tk
            FROM message WHERE json_valid(data) AND json_extract(data, '$.role') = 'assistant' AND p IN (\(marks)) AND t >= ?
            """
        var stats = LocalStats(), seen = Set<String>(), prompts = Set<String>(), sessions = Set<String>()
        var byDay: [Date: Int] = [:], byModel: [String: Int] = [:]
        for row in (Kit.sqlite(db, v2, params) ?? []) + (Kit.sqlite(db, v1, params) ?? []) {
            let id = "\(row["id"] ?? "")", provider = "\(row["p"] ?? "")", rawModel = row["m"] as? String ?? ""
            guard seen.insert(id).inserted, accept(provider, rawModel), let created = Kit.date(row["t"]) else { continue }
            let total = Int(Kit.number(row["tk"]) ?? 0), day = calendar.startOfDay(for: created)
            stats.tokensWeek += total
            byDay[day, default: 0] += total
            if total > 0 { byModel[model(rawModel), default: 0] += total }
            guard day == today else { continue }
            stats.tokensToday += total
            let session = "\(row["s"] ?? "")"
            sessions.insert(session)
            // A reply books the user message it answers; V2 rows carry no parent, so each counts once.
            prompts.insert(session + "/" + ((row["parent"] as? String) ?? id))
        }
        stats.promptsToday = prompts.count
        stats.sessionsToday = sessions.count
        stats.topModel = byModel.max { $0.value < $1.value }?.key
        stats.busiestDay = byDay.filter { $0.value > 0 }.max { $0.value < $1.value }?.key
        if !stats.isEmpty { return (stats, true) }

        // Nothing this week: any reply ever on these providers still means opencode used them here.
        let ever = ["message", "session_message"].map { table in
            """
            SELECT COALESCE(json_extract(data, '$.providerID'), json_extract(data, '$.model.providerID')) AS p,
              COALESCE(json_extract(data, '$.modelID'), json_extract(data, '$.model.id')) AS m
            FROM \(table) WHERE json_valid(data) AND p IN (\(marks)) GROUP BY p, m
            """
        }
        let used = ever.flatMap { Kit.sqlite(db, $0, providers) ?? [] }.contains {
            accept("\($0["p"] ?? "")", $0["m"] as? String ?? "")
        }
        return (nil, used)
    }

    static func lastPathModel(_ raw: String, fallback: String) -> String {
        let name = raw.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? fallback : name
    }
}

/// Keeps the last good limits, plan and balance when a check fails.
private func planKept(_ previous: AgentUsage?, note: String?, stats: LocalStats?) -> AgentUsage {
    var usage = previous ?? AgentUsage()
    usage.note = note
    usage.stats = stats
    return usage
}

/// Data here but no key: local stats plus how to add one.
private func planNoKey(_ local: (stats: LocalStats?, used: Bool), note: String) -> AgentUsage? {
    local.used ? AgentUsage(note: note, stats: local.stats, fetchedAt: Date()) : nil
}

// MARK: Z.ai

struct ZaiCollector: UsageCollector {
    let id = "zai"
    let displayName = "Z.ai"
    let symbol = "z.circle"

    private static let providers = ["zai", "zhipu", "zai-coding-cn", "zhipu-coding-plan", "zhipuai", "zai-coding-plan", "zhipuai-coding-plan"]
    private static let hosts = ["zai": "https://api.z.ai", "zhipu": "https://open.bigmodel.cn"]
    private static let signIn = "aggiorna la chiave in ~/.config/notchlite/agents/zai.json o ZAI_API_KEY"

    /// Config first, then the environment, then pi/omp's `.env`, then pi/omp/opencode `auth.json`.
    private func credentials() -> (key: String, platform: String)? {
        let config = PlanAuth.config(id)
        let configured = PlanAuth.string(config["platform"])?.lowercased()
        var found: (String, String)?
        if let key = PlanAuth.resolve(config["apiKey"] as? String) {
            found = (key, "zai")
        } else if let key = Kit.env("ZAI_API_KEY") {
            found = (key, "zai")
        } else if let key = Kit.env("ZHIPU_API_KEY") ?? Kit.env("ZHIPUAI_API_KEY") {
            found = (key, "zhipu")
        }
        if found == nil {
            for file in [PlanAuth.ompDir, PlanAuth.piDir].map({ $0.appendingPathComponent(".env") }) {
                let values = PlanAuth.dotenv(file)
                if let key = values["ZAI_API_KEY"] { found = (key, "zai"); break }
                if let key = values["ZHIPU_API_KEY"] ?? values["ZHIPUAI_API_KEY"] { found = (key, "zhipu"); break }
            }
        }
        if found == nil, let hit = PlanAuth.key(in: [PlanAuth.piAuth, PlanAuth.ompAuth] + PlanAuth.openCodeAuth,
                                               providers: ["zai", "zhipu", "zai-coding-plan", "zhipuai-coding-plan", "zhipuai"]) {
            found = (hit.key, hit.provider.hasPrefix("zhipu") ? "zhipu" : "zai")
        }
        guard let found else { return nil }
        let chosen = configured ?? found.1
        return (found.0, Self.hosts[chosen] == nil ? "zai" : chosen)
    }

    func fetch(previous: AgentUsage?) -> AgentUsage? {
        let local = PlanLocal.openCode(providers: Self.providers) { $0.isEmpty ? "glm" : PlanLocal.lastPathModel($0, fallback: "glm") }
        guard let found = credentials() else {
            return planNoKey(local, note: "Aggiungi ZAI_API_KEY o ~/.config/notchlite/agents/zai.json per vedere i limiti del Coding Plan")
        }
        let (key, platform) = found
        let url = URL(string: Self.hosts[platform]! + "/api/monitor/usage/quota/limit")!
        // This endpoint takes the raw token, not a Bearer prefix.
        let response = Kit.request(url, headers: ["Authorization": key, "Accept-Language": "en-US,en",
                                                  "Content-Type": "application/json"], timeout: 15)
        guard response.ok, let body = response.object else {
            let note = response.ok ? "Risposta non valida da Z.ai"
                : Kit.failureNote(response, provider: "Z.ai", signIn: Self.signIn)
            return planKept(previous, note: note, stats: local.stats)
        }
        guard let data = body["data"] as? [String: Any], let rows = data["limits"] as? [[String: Any]] else {
            // HTTP 200 carries refusals and "no coding plan" in the body.
            let code = Kit.number(body["code"]).map { Int($0) } ?? 0
            if [1000, 1001, 1003, 1005].contains(code) {
                return planKept(previous, note: "Accesso rifiutato: \(Self.signIn)", stats: local.stats)
            }
            if ((body["msg"] as? String) ?? "").lowercased().contains("coding plan") {
                // Pay-as-you-go key: no plan windows, which is no trouble.
                return AgentUsage(plan: "Pay-as-you-go", stats: local.stats, fetchedAt: Date())
            }
            let message = PlanAuth.string(body["msg"]).map { "Z.ai: \($0.prefix(120))" }
            return planKept(previous, note: message ?? "Z.ai non ha restituito limiti", stats: local.stats)
        }
        var limits: [UsageLimit] = []
        for row in rows where ["CREDIT_LIMIT", "TOKENS_LIMIT"].contains(row["type"] as? String ?? "") {
            let window = (Kit.number(row["unit"]).map { Int($0) }, Kit.number(row["number"]).map { Int($0) })
            let label: String
            switch window {
            case (3?, 5?): label = "Sessione (5 ore)"
            case (6?, 1?): label = "Settimana"
            default: continue
            }
            guard let percent = Kit.number(row["percentage"]) else { continue }
            limits.append(Kit.limit(label, used: percent / 100, resetsAt: row["nextResetTime"]))
        }
        guard !limits.isEmpty else { return planKept(previous, note: "Z.ai non ha restituito limiti", stats: local.stats) }
        let level = PlanAuth.string(data["level"]).map { Kit.capitalized($0.lowercased()) }
        return AgentUsage(plan: level ?? "Coding Plan", limits: limits, stats: local.stats, fetchedAt: Date())
    }
}

// MARK: MiniMax

struct MiniMaxCollector: UsageCollector {
    let id = "minimax"
    let displayName = "MiniMax"
    let symbol = "m.circle"

    private static let providers = ["minimax", "minimax-cn", "minimax-coding-plan", "minimax-cn-coding-plan"]
    private static let global = "https://api.minimax.io", china = "https://api.minimaxi.com"
    private static let domains = ["minimax.io", "minimaxi.com", "minimax.chat", "minimaxi.chat"]
    private static let signIn = "imposta MINIMAX_API_KEY o accedi di nuovo con `mmx` o opencode"

    private func mmxConfig() -> [String: Any] {
        let dir = Kit.expand(Kit.env("MMX_CONFIG_DIR") ?? "~/.mmx")
        if let json = Kit.readJSON(dir.appendingPathComponent("config.json")), !json.isEmpty { return json }
        // Older mmx releases kept YAML; only the one scalar is needed.
        for line in (Kit.readText(dir.appendingPathComponent("config.yaml")) ?? "").split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "api_key" {
                return ["api_key": parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))]
            }
        }
        return [:]
    }

    /// (key, host): the host follows where the key came from; `MINIMAX_BASE_URL` overrides.
    private func credentials() -> (key: String, host: String)? {
        let regionHost = Kit.env("MINIMAX_REGION") == "cn" ? Self.china : Self.global
        var found: (String, String)?
        if let key = Kit.env("MINIMAX_API_KEY") {
            found = (key, regionHost)
        } else if let key = PlanAuth.resolve(PlanAuth.config(id)["apiKey"] as? String) {
            found = (key, regionHost)
        } else {
            let config = mmxConfig()
            let oauth = config["oauth"] as? [String: Any] ?? [:]
            if let key = PlanAuth.string(config["api_key"]) ?? PlanAuth.string(config["apiKey"]) ?? PlanAuth.string(oauth["access_token"]) {
                var host = PlanAuth.string(config["base_url"]) ?? PlanAuth.string(oauth["resource_url"])
                if host == nil {
                    let region = [Kit.env("MINIMAX_REGION"), config["region"] as? String, oauth["region"] as? String]
                        .compactMap { $0 }.first { $0 == "cn" || $0 == "global" }
                    host = region == "cn" ? Self.china : Self.global
                }
                found = (key, host ?? Self.global)
            } else if let hit = PlanAuth.key(in: PlanAuth.openCodeAuth + [PlanAuth.piAuth, PlanAuth.ompAuth], providers: Self.providers) {
                found = (hit.key, hit.provider.hasPrefix("minimax-cn") ? Self.china : Self.global)
            }
        }
        guard let found else { return nil }
        return (found.0, Kit.env("MINIMAX_BASE_URL") ?? found.1)
    }

    func fetch(previous: AgentUsage?) -> AgentUsage? {
        let local = PlanLocal.openCode(providers: Self.providers) { PlanLocal.lastPathModel($0, fallback: "minimax") }
        guard let found = credentials() else {
            return planNoKey(local, note: "Imposta MINIMAX_API_KEY o accedi a MiniMax in opencode per vedere i limiti del Token Plan")
        }
        let (key, host) = found
        guard let base = PlanAuth.official(host, domains: Self.domains) else {
            return planKept(previous, note: "Host MiniMax non ufficiale: la chiave non è stata inviata", stats: local.stats)
        }
        let response = Kit.request(base.appendingPathComponent("v1/token_plan/remains"),
                                   headers: ["Authorization": "Bearer \(key)", "Content-Type": "application/json"], timeout: 12)
        guard response.ok, let body = response.object else {
            let note = response.ok ? "Risposta non valida da MiniMax"
                : Kit.failureNote(response, provider: "MiniMax", signIn: Self.signIn)
            return planKept(previous, note: note, stats: local.stats)
        }
        if let status = (body["base_resp"] as? [String: Any]).flatMap({ Kit.number($0["status_code"]) }), status != 0 {
            let note = [1004, 2049].contains(Int(status)) ? "Accesso rifiutato: \(Self.signIn)"
                : "MiniMax: \(((body["base_resp"] as? [String: Any])?["status_msg"] as? String ?? "richiesta rifiutata").prefix(120))"
            return planKept(previous, note: note, stats: local.stats)
        }
        let limits = Self.limits(body["model_remains"] as? [[String: Any]] ?? [])
        guard !limits.isEmpty else { return planKept(previous, note: "MiniMax non ha restituito limiti", stats: local.stats) }
        return AgentUsage(plan: "Token Plan", limits: limits, stats: local.stats, fetchedAt: Date())
    }

    /// The `general` quota's windows (else the first non-media model's), skipping models not in plan.
    private static func limits(_ rows: [[String: Any]]) -> [UsageLimit] {
        let n = { (row: [String: Any], key: String) in Kit.number(row[key]) }
        let inPlan = rows.filter { row in
            !(n(row, "current_interval_total_count") == 0 && n(row, "current_weekly_total_count") == 0
              && n(row, "current_interval_status") == 3 && n(row, "current_weekly_status") == 3)
        }
        let media = ["video", "image", "audio", "vision"]
        guard let row = inPlan.first(where: { $0["model_name"] as? String == "general" })
            ?? inPlan.first(where: { row in
                let name = (row["model_name"] as? String ?? "").lowercased()
                return !media.contains { name.contains($0) }
            }) else { return [] }

        func window(_ label: String, percent: String, status: String, end: String, remains: String) -> UsageLimit? {
            // Status 2 is exhausted whatever the percentage says, 3 unlimited (no meter).
            let used: Double
            switch n(row, status) {
            case 2?: used = 1
            case 3?: return nil
            default:
                guard let remaining = n(row, percent) else { return nil }
                used = 1 - remaining / 100
            }
            var reset: Date? = Kit.date(row[end])
            if reset == nil, let ms = n(row, remains), ms > 0 { reset = Date().addingTimeInterval(ms / 1000) }
            return UsageLimit(label: label, percent: Kit.clamp(used), resetsAt: reset)
        }
        return [
            window("Sessione (5 ore)", percent: "current_interval_remaining_percent", status: "current_interval_status",
                   end: "end_time", remains: "remains_time"),
            window("Settimana", percent: "current_weekly_remaining_percent", status: "current_weekly_status",
                   end: "weekly_end_time", remains: "weekly_remains_time"),
        ].compactMap { $0 }
    }
}

// MARK: Synthetic

struct SyntheticCollector: UsageCollector {
    let id = "synthetic"
    let displayName = "Synthetic"
    let symbol = "s.circle"

    private func apiKey() -> String? {
        if let key = Kit.env("SYNTHETIC_API_KEY") ?? PlanAuth.resolve(PlanAuth.config(id)["apiKey"] as? String) { return key }
        // pi, omp, opencode, then pi/omp profiles.
        var files = [PlanAuth.piAuth, PlanAuth.ompAuth] + PlanAuth.openCodeAuth
        for base in [".pi/profiles", ".omp/profiles"].map({ Kit.home.appendingPathComponent($0) }) {
            let children = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            files += children.sorted { $0.path < $1.path }.map { $0.appendingPathComponent("agent/auth.json") }
        }
        return PlanAuth.key(in: files, providers: ["synthetic"])?.key
    }

    func fetch(previous: AgentUsage?) -> AgentUsage? {
        let local = PlanLocal.openCode(providers: ["synthetic"]) { raw in
            PlanLocal.lastPathModel(raw.hasPrefix("hf:") ? String(raw.dropFirst(3)) : raw, fallback: "synthetic")
        }
        guard let key = apiKey() else {
            return planNoKey(local, note: "Imposta SYNTHETIC_API_KEY o accedi a Synthetic in pi, omp o opencode per vedere le quote")
        }
        let base = Kit.env("SYNTHETIC_API_BASE_URL") ?? "https://api.synthetic.new"
        guard let host = PlanAuth.official(base, domains: ["synthetic.new"]) else {
            return planKept(previous, note: "Host Synthetic non ufficiale: la chiave non è stata inviata", stats: local.stats)
        }
        let response = Kit.request(host.appendingPathComponent("v2/quotas"),
                                   headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"])
        guard response.ok, let body = response.object else {
            let note = response.ok ? "Risposta non valida da Synthetic"
                : Kit.failureNote(response, provider: "Synthetic", signIn: "imposta una SYNTHETIC_API_KEY valida o accedi di nuovo a Synthetic")
            return planKept(previous, note: note, stats: local.stats)
        }
        let limits = Self.limits(body)
        guard !limits.isEmpty else { return planKept(previous, note: "Synthetic non ha restituito quote", stats: local.stats) }
        return AgentUsage(limits: limits, stats: local.stats, fetchedAt: Date())
    }

    private static func limits(_ body: [String: Any]) -> [UsageLimit] {
        var limits: [UsageLimit] = []
        // The rolling requests and weekly credits regenerate gradually: no reset time.
        let rolling = body["rollingFiveHourLimit"] as? [String: Any] ?? [:]
        if let remaining = Kit.number(rolling["remaining"]), let max = Kit.number(rolling["max"]), max > 0 {
            let used = rolling["limited"] as? Bool == true ? 1 : 1 - remaining / max
            limits.append(Kit.limit("Richieste (5 ore)", used: used))
        }
        if let left = Kit.number((body["weeklyTokenLimit"] as? [String: Any])?["percentRemaining"]) {
            limits.append(Kit.limit("Crediti settimanali", used: 1 - left / 100))
        }
        func requests(_ label: String, _ value: Any?) -> UsageLimit? {
            guard let window = value as? [String: Any], let used = Kit.number(window["requests"]),
                  let max = Kit.number(window["limit"]), max > 0 else { return nil }
            return Kit.limit(label, used: used / max, resetsAt: window["renewsAt"])
        }
        if limits.isEmpty, let subscription = requests("Richieste abbonamento", body["subscription"]) {
            limits.append(subscription)
        }
        limits += [requests("Ricerca (oraria)", (body["search"] as? [String: Any])?["hourly"]),
                   requests("Chiamate strumenti gratuite", body["freeToolCalls"])].compactMap { $0 }
        return limits
    }
}

// MARK: Ollama Cloud

struct OllamaCloudCollector: UsageCollector {
    let id = "ollama"
    let displayName = "Ollama Cloud"
    let symbol = "cloud"

    private func apiKey(_ config: [String: Any]) -> String? {
        Kit.env("OLLAMA_API_KEY") ?? PlanAuth.resolve(config["apiKey"] as? String)
            ?? PlanAuth.key(in: [PlanAuth.piAuth, PlanAuth.ompAuth] + PlanAuth.openCodeAuth, providers: ["ollama-cloud"])?.key
    }

    /// Cloud-tagged models ("glm-4.6:cloud", "gpt-oss:120b-cloud") run on Ollama's servers too.
    private static func cloudModel(_ model: String) -> Bool {
        guard let tag = model.lowercased().split(separator: ":").last, model.contains(":") else { return false }
        return tag == "cloud" || tag.hasSuffix("-cloud")
    }

    func fetch(previous: AgentUsage?) -> AgentUsage? {
        let config = PlanAuth.config(id)
        let prefix = PlanAuth.string(config["modelPrefix"])?.lowercased() ?? ""
        let name = { (raw: String) in raw.split(separator: ":").first.map(String.init) ?? "ollama" }
        let local = PlanLocal.openCode(providers: ["ollama-cloud", "ollama"], accept: { provider, model in
            (provider == "ollama-cloud" || Self.cloudModel(model)) && (prefix.isEmpty || name(model).lowercased().hasPrefix(prefix))
        }, model: { name($0).isEmpty ? "ollama" : name($0) })
        guard let key = apiKey(config) else {
            return planNoKey(local, note: "Imposta OLLAMA_API_KEY o apiKey in ~/.config/notchlite/agents/ollama.json per vedere i limiti")
        }
        let headers = ["Authorization": "Bearer \(key)", "Accept": "application/json"]
        let response = Kit.request(URL(string: "https://ollama.com/api/balance")!, headers: headers)
        guard response.ok, let body = response.object else {
            let note = response.ok ? "Risposta non valida da Ollama"
                : Kit.failureNote(response, provider: "Ollama", signIn: "aggiorna OLLAMA_API_KEY o accedi di nuovo in pi")
            return planKept(previous, note: note, stats: local.stats)
        }

        var limits: [UsageLimit] = []
        let included = body["included"] as? [String: Any] ?? [:]
        for (field, label) in [("session", "Sessione (5 ore)"), ("weekly", "Settimana")] {
            // A legacy plan reports what is left, 0...100.
            guard let window = included[field] as? [String: Any], let left = Kit.number(window["remaining_percent"]),
                  left >= 0 else { continue }
            limits.append(Kit.limit(label, used: 1 - min(left / 100, 1), resetsAt: window["resets_at"]))
        }
        if let left = Kit.number(included["balance_usd"]), let allowance = Kit.number(included["allowance_usd"]), allowance > 0 {
            limits.append(Kit.limit("Crediti inclusi", used: (allowance - left) / allowance,
                                    resetsAt: (included["period"] as? [String: Any])?["until"]))
        }
        // Credits bought on top of the plan: only what remains is known.
        let purchased = Kit.number((body["purchased"] as? [String: Any])?["balance_usd"]).flatMap { $0 > 0 ? $0 : nil }
        guard !limits.isEmpty || purchased != nil else {
            return planKept(previous, note: "Ollama non ha restituito limiti", stats: local.stats)
        }

        // The plan name; a failed lookup keeps the last one.
        var plan = previous?.plan
        let me = Kit.request(URL(string: "https://ollama.com/api/me")!, method: "POST", headers: headers)
        if me.ok, let object = me.object {
            plan = PlanAuth.string(object["plan"] ?? object["Plan"]).map { Kit.capitalized(String($0.prefix(64))) }
        }
        return AgentUsage(plan: plan, limits: limits, balance: purchased.map { Kit.money($0) },
                          stats: local.stats, fetchedAt: Date())
    }
}

// MARK: OpenCode

struct OpenCodeCollector: UsageCollector {
    let id = "opencode"
    let displayName = "OpenCode"
    let symbol = "curlybraces"

    private static let providers = ["opencode", "opencode-go"]

    private struct Credential {
        let token: String
        let url: URL
        var headers: [String: String] = [:]
        var expired = false
    }

    /// Env keys, opencode's own store, its/pi/omp `auth.json`, and last the Console session.
    private func candidates() -> [Credential] {
        var tokens = [Kit.env("OPENCODE_API_KEY"), Kit.env("OPENCODE_GO_API_KEY"),
                      PlanAuth.resolve(PlanAuth.config(id)["apiKey"] as? String)].compactMap { $0 }
        var console: Credential?
        if let db = PlanLocal.openCodeDB {
            let sql = """
                SELECT integration_id, value FROM credential WHERE active = 1 AND integration_id IN ('opencode-go', 'opencode')
                ORDER BY integration_id = 'opencode-go' DESC, time_updated DESC
                """
            for row in Kit.sqlite(db, sql) ?? [] {
                guard let raw = (row["value"] as? String)?.data(using: .utf8),
                      let value = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { continue }
                if value["type"] as? String == "key", let key = PlanAuth.string(value["key"]) {
                    tokens.append(key)
                } else if value["type"] as? String == "oauth", console == nil, let access = PlanAuth.string(value["access"]) {
                    let org = PlanAuth.string((value["metadata"] as? [String: Any])?["orgID"])
                    let expires = Kit.number(value["expires"]) ?? 0
                    console = Credential(token: access, url: URL(string: "https://opencode.ai/inference/go/v1/usage")!,
                                         headers: org.map { ["x-opencode-org-id": $0] } ?? [:],
                                         expired: expires > 0 && expires <= Date().timeIntervalSince1970 * 1000)
                }
            }
        }
        for file in PlanAuth.openCodeAuth + [PlanAuth.piAuth, PlanAuth.ompAuth] {
            if let hit = PlanAuth.key(in: file, providers: Self.providers) { tokens.append(hit.key) }
        }
        var unique: [String] = []
        for token in tokens where !unique.contains(token) { unique.append(token) }
        let go = URL(string: "https://opencode.ai/zen/go/v1/usage")!
        return unique.map { Credential(token: $0, url: go) } + (console.map { [$0] } ?? [])
    }

    func fetch(previous: AgentUsage?) -> AgentUsage? {
        let local = PlanLocal.openCode(providers: Self.providers) { raw in
            var name = PlanLocal.lastPathModel(raw, fallback: "opencode").split(separator: ":").first.map(String.init) ?? "opencode"
            if name.lowercased().hasPrefix("glm") { name = "GLM" + name.dropFirst(3) }
            return name
        }
        let credentials = candidates()
        guard !credentials.isEmpty else {
            return planNoKey(local, note: "Imposta OPENCODE_API_KEY o collega OpenCode Go con /connect per vedere i limiti")
        }

        // A refused credential hands over to the next; a key without Go (Zen pay-as-you-go) is no trouble.
        var refused: Credential?, noPlan = false
        for credential in credentials {
            var headers = ["Authorization": "Bearer \(credential.token)", "Accept": "application/json"]
            headers.merge(credential.headers) { $1 }
            let response = Kit.request(credential.url, headers: headers)
            switch response.status {
            case 401: refused = refused ?? credential; continue
            case 403: noPlan = true; continue
            default: break
            }
            guard response.ok, let body = response.object else {
                let note = response.ok ? "Risposta non valida da OpenCode"
                    : Kit.failureNote(response, provider: "OpenCode", signIn: "ricollega OpenCode Go con /connect")
                return planKept(previous, note: note, stats: local.stats)
            }
            let limits = Self.limits(body)
            guard !limits.isEmpty else { return planKept(previous, note: "OpenCode non ha restituito limiti", stats: local.stats) }
            return AgentUsage(plan: "Go", limits: limits, stats: local.stats, fetchedAt: Date())
        }
        if noPlan { return AgentUsage(plan: "Zen", stats: local.stats, fetchedAt: Date()) }
        let note = refused?.expired == true
            ? "Sessione della Console OpenCode scaduta: esegui `opencode auth login`"
            : "Accesso rifiutato: ricollega OpenCode Go con /connect o imposta OPENCODE_API_KEY"
        return planKept(previous, note: note, stats: local.stats)
    }

    private static func limits(_ payload: [String: Any]) -> [UsageLimit] {
        let usage = payload["usage"] as? [String: Any] ?? payload
        return [("rolling", "Sessione (5 ore)"), ("weekly", "Settimana"), ("monthly", "Mese")].compactMap { name, label in
            guard let window = usage[name] as? [String: Any] ?? payload[name + "Usage"] as? [String: Any],
                  var used = Kit.number(window["percent"] ?? window["usagePercent"]).map({ $0 / 100 }) else { return nil }
            if window["status"] as? String == "rate-limited" { used = 1 }
            var reset = Kit.date(window["resetsAt"])
            if reset == nil, let seconds = Kit.number(window["resetInSec"]), seconds > 0 {
                reset = Date().addingTimeInterval(seconds)
            }
            return UsageLimit(label: label, percent: Kit.clamp(used), resetsAt: reset)
        }
    }
}
