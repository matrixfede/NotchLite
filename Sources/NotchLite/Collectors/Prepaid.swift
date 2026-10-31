// Prepaid credit for OpenRouter, DeepSeek, Fireworks and Kimchi, after Omarchy's collectors (MIT, basecamp/omarchy).

import Foundation

// MARK: Shared

private enum PrepaidKit {
    static var configHome: URL {
        Kit.env("XDG_CONFIG_HOME").map { URL(fileURLWithPath: $0) } ?? Kit.home.appendingPathComponent(".config")
    }
    static var dataHome: URL {
        Kit.env("XDG_DATA_HOME").map { URL(fileURLWithPath: $0) } ?? Kit.home.appendingPathComponent(".local/share")
    }
    static var piAuth: URL {
        (Kit.env("PI_CODING_AGENT_DIR").map { Kit.expand($0) } ?? Kit.home.appendingPathComponent(".pi/agent"))
            .appendingPathComponent("auth.json")
    }
    static var ompAuth: URL { Kit.home.appendingPathComponent(".omp/agent/auth.json") }
    static var opencodeAuth: URL { dataHome.appendingPathComponent("opencode/auth.json") }

    /// NotchLite's own per-agent settings (Omarchy's `~/.config/omarchy/agents/<id>.json` shape).
    static func settings(_ id: String) -> [String: Any] {
        Kit.readJSON(configHome.appendingPathComponent("notchlite/agents/\(id).json")) ?? [:]
    }

    static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// A provider's key from an opencode / pi / omp auth.json, `$VAR` resolved.
    static func authKey(_ url: URL, _ provider: String, onlyAPIKeys: Bool = false) -> String? {
        var entry = Kit.readJSON(url)?[provider]
        if let object = entry as? [String: Any] {
            if onlyAPIKeys, let type = object["type"] as? String, type != "api_key" { return nil }
            entry = object["key"] ?? object["apiKey"] ?? object["api_key"]
        }
        return string(entry).flatMap(resolve)
    }

    /// Literal keys and `$VAR` / `${VAR}` references; a pi `!command` is never run or sent.
    static func resolve(_ raw: String) -> String? {
        guard !raw.hasPrefix("!") else { return nil }
        guard raw.contains("$") else { return raw }
        let escaped = raw.replacingOccurrences(of: "$$", with: "\u{0}").replacingOccurrences(of: "$!", with: "\u{1}")
        guard let regex = try? NSRegularExpression(pattern: #"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))"#) else { return nil }
        var text = escaped
        for match in regex.matches(in: escaped, range: NSRange(escaped.startIndex..., in: escaped)).reversed() {
            let group = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard let nameRange = Range(group, in: escaped), let whole = Range(match.range, in: text),
                  let value = Kit.env(String(escaped[nameRange])) else { return nil }
            text.replaceSubrange(whole, with: value)
        }
        let key = text.replacingOccurrences(of: "\u{0}", with: "$").replacingOccurrences(of: "\u{1}", with: "!")
        return key.isEmpty ? nil : key
    }

    static func start(_ previous: AgentUsage?, plan: String? = "Prepagato") -> AgentUsage {
        var result = previous ?? AgentUsage()
        if result.plan == nil { result.plan = plan }
        return result
    }

    /// Draining meter: share of the funded amount already spent.
    static func spent(_ label: String, spent: Double, funded: Double) -> UsageLimit {
        Kit.limit(label, used: funded > 0 ? spent / funded : 0)
    }

    static func replacing(_ limits: [UsageLimit], where match: (UsageLimit) -> Bool, with fresh: [UsageLimit]) -> [UsageLimit] {
        fresh + limits.filter { !match($0) }
    }

    static func header(_ key: String) -> [String: String] {
        ["Authorization": "Bearer \(key)", "Accept": "application/json"]
    }

    static let creditLabel = "Credito"
    static let outOfCredits = "Credito esaurito"
}

/// Inference keys OpenRouter refused /credits for, asked again after a day (in memory only).
private let openRouterRefusals = Locked<[Int: Date]>([:])

// MARK: OpenRouter

struct OpenRouterCollector: UsageCollector {
    let id = "openrouter"
    let displayName = "OpenRouter"
    let symbol = "point.3.connected.trianglepath.dotted"
    private let api = "https://openrouter.ai/api/v1"
    private let signIn = "imposta OPENROUTER_API_KEY o accedi a OpenRouter in opencode, pi o omp"

    private enum Failure { case http(Kit.Response, manager: Bool), invalid }

    func fetch(previous: AgentUsage?) -> AgentUsage? {
        let settings = PrepaidKit.settings(id)
        let key = Kit.env("OPENROUTER_API_KEY")
            ?? PrepaidKit.authKey(PrepaidKit.opencodeAuth, "openrouter")
            ?? PrepaidKit.authKey(PrepaidKit.piAuth, "openrouter")
            ?? PrepaidKit.authKey(PrepaidKit.ompAuth, "openrouter")
            ?? PrepaidKit.string(settings["apiKey"])
        let manager = Kit.env("OPENROUTER_MANAGEMENT_KEY") ?? PrepaidKit.string(settings["managementKey"])
        guard key != nil || manager != nil else { return nil }

        var result = PrepaidKit.start(previous)
        var failures: [Failure] = []

        // Key-limit meter: only an inference key has one.
        if let key {
            let response = get("/key", key)
            if !response.ok {
                failures.append(.http(response, manager: false))
            } else if let data = response.object?["data"] as? [String: Any], let meter = keyMeter(data) {
                result.limits = PrepaidKit.replacing(result.limits, where: { $0.label.hasPrefix("Limite chiave") },
                                                     with: meter.map { [$0] } ?? [])
            } else {
                failures.append(.invalid)
            }
        } else {
            result.limits.removeAll { $0.label.hasPrefix("Limite chiave") }
        }

        // Balance: /credits is documented as management-key only.
        var credits: [String: Any]?
        var creditsFailure: Failure?
        var managerRefused = false
        if let manager {
            let response = get("/credits", manager)
            if response.ok {
                credits = response.object?["data"] as? [String: Any] ?? [:]
            } else {
                managerRefused = [401, 403].contains(response.status)
                creditsFailure = .http(response, manager: true)
            }
        }
        var refusedInference = false
        if let key, manager == nil || managerRefused {
            let slot = key.hashValue
            if let refused = openRouterRefusals.value[slot], Date().timeIntervalSince(refused) < 86_400 {
                refusedInference = true
            } else {
                let response = get("/credits", key)
                if response.ok {
                    credits = response.object?["data"] as? [String: Any] ?? [:]
                    creditsFailure = nil
                } else if response.status == 403 {
                    openRouterRefusals.mutate { $0[slot] = Date() }
                    refusedInference = true
                } else {
                    creditsFailure = .http(response, manager: false)
                }
            }
        }
        if let credits {
            if let total = Kit.number(credits["total_credits"]), let used = Kit.number(credits["total_usage"]) {
                if total > 0 {
                    result.balance = Kit.money(max(0, total - used))
                    result.limits = PrepaidKit.replacing(result.limits, where: { $0.label == PrepaidKit.creditLabel },
                                                         with: [PrepaidKit.spent(PrepaidKit.creditLabel, spent: max(0, used), funded: total)])
                } else {
                    clearBalance(&result)
                }
            } else {
                failures.append(.invalid)
            }
        } else if let creditsFailure {
            failures.append(creditsFailure)
        } else if refusedInference {
            clearBalance(&result) // an inference key simply can't read the balance
        }

        result.extra = result.balance == nil && refusedInference && manager == nil
            ? "Saldo leggibile solo con una management key (OPENROUTER_MANAGEMENT_KEY)" : nil
        result.note = note(failures)
        if failures.isEmpty { result.fetchedAt = Date() }
        return result
    }

    private func get(_ path: String, _ key: String) -> Kit.Response {
        Kit.request(URL(string: api + path)!, headers: PrepaidKit.header(key), timeout: 15)
    }

    private func clearBalance(_ result: inout AgentUsage) {
        result.balance = nil
        result.limits.removeAll { $0.label == PrepaidKit.creditLabel }
    }

    /// nil = unreadable answer; .some(nil) = a key without a credit limit.
    private func keyMeter(_ data: [String: Any]) -> UsageLimit?? {
        guard data.keys.contains("limit") else { return nil }
        if data["limit"] is NSNull { return .some(nil) }
        guard let limit = Kit.number(data["limit"]), let remaining = Kit.number(data["limit_remaining"]) else { return nil }
        guard limit > 0 else { return .some(nil) }
        let period = ["daily": " giornaliero", "weekly": " settimanale", "monthly": " mensile"][
            (data["limit_reset"] as? String ?? "").lowercased()] ?? ""
        return .some(Kit.limit("Limite chiave" + period, used: (limit - min(max(0, remaining), limit)) / limit))
    }

    private func note(_ failures: [Failure]) -> String? {
        let refused = failures.compactMap { failure -> Bool? in
            if case let .http(response, manager) = failure, [401, 403].contains(response.status) { return manager }
            return nil
        }
        if !refused.isEmpty {
            return refused.allSatisfy { $0 } ? "Accesso rifiutato: sostituisci la management key OpenRouter"
                : "Accesso rifiutato: \(signIn)"
        }
        switch failures.first {
        case let .http(response, _)?: return Kit.failureNote(response, provider: "OpenRouter", signIn: signIn)
        case .invalid?: return "Risposta di OpenRouter non valida"
        case nil: return nil
        }
    }
}

// MARK: DeepSeek

struct DeepSeekCollector: UsageCollector {
    let id = "deepseek"
    let displayName = "DeepSeek"
    let symbol = "fish"
    private let endpoint = URL(string: "https://api.deepseek.com/user/balance")!

    func fetch(previous: AgentUsage?) -> AgentUsage? {
        guard let key = apiKey() else { return nil }
        var result = PrepaidKit.start(previous)
        let response = Kit.request(endpoint, headers: PrepaidKit.header(key), timeout: 15)
        guard response.ok, let object = response.object else {
            result.note = Kit.failureNote(response, provider: "DeepSeek", signIn: "imposta una DEEPSEEK_API_KEY valida")
            return result
        }
        // One entry per currency: the one holding credit, else the first readable.
        let readable = (object["balance_infos"] as? [[String: Any]] ?? []).compactMap { info -> (Double, [String: Any])? in
            guard !(info["total_balance"] is NSNull), let total = Kit.number(info["total_balance"]) else { return nil }
            return (total, info)
        }
        guard let chosen = readable.first(where: { $0.0 > 0 }) ?? readable.first else {
            result.note = "Risposta di DeepSeek senza saldo"
            return result
        }
        let (remaining, info) = chosen
        let currency = PrepaidKit.string(info["currency"]) ?? "CNY"
        result.balance = Kit.money(max(0, remaining), currency: currency)

        let funded = max(0, Kit.number(PrepaidKit.settings(id)["fundedAmount"]) ?? 0)
        result.limits = funded > 0
            ? [PrepaidKit.spent(PrepaidKit.creditLabel, spent: max(0, funded - remaining), funded: funded)] : []
        let available = (object["is_available"] as? Bool) != false && remaining > 0
        result.note = available ? nil : PrepaidKit.outOfCredits
        result.fetchedAt = Date()
        return result
    }

    private func apiKey() -> String? {
        let dsh = Kit.env("DSH_HOME").map { Kit.expand($0) } ?? Kit.home.appendingPathComponent(".dsh")
        return Kit.env("DEEPSEEK_API_KEY")
            ?? PrepaidKit.authKey(PrepaidKit.piAuth, "deepseek")
            ?? PrepaidKit.authKey(PrepaidKit.ompAuth, "deepseek")
            ?? PrepaidKit.authKey(PrepaidKit.opencodeAuth, "deepseek")
            ?? credentialsYAMLKey(dsh.appendingPathComponent(".credentials.yaml"))
            ?? dotenvKey(dsh.appendingPathComponent(".env"))
    }

    /// DEEPSEEK_API_KEY under `refs:` (or at the top level, older layout) of dsh's store.
    private func credentialsYAMLKey(_ url: URL) -> String? {
        guard let text = Kit.readText(url) else { return nil }
        var section = ""
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            if line.first?.isWhitespace == false {
                section = name
                if name == "DEEPSEEK_API_KEY", parts.count == 2 { return unquote(parts[1]) }
            } else if section == "refs", name == "DEEPSEEK_API_KEY", parts.count == 2 {
                return unquote(parts[1])
            }
        }
        return nil
    }

    private func dotenvKey(_ url: URL) -> String? {
        guard let text = Kit.readText(url) else { return nil }
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "DEEPSEEK_API_KEY" { return unquote(parts[1]) }
        }
        return nil
    }

    private func unquote(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if let quote = value.first, quote == "'" || quote == "\"" {
            let body = value.dropFirst()
            guard let end = body.firstIndex(of: quote) else { return nil }
            return PrepaidKit.string(String(body[..<end]))
        }
        return PrepaidKit.string(value.components(separatedBy: " #")[0])
    }
}

// MARK: Fireworks

struct FireworksCollector: UsageCollector {
    let id = "fireworks"
    let displayName = "Fireworks"
    let symbol = "flame"
    private let api = "https://api.fireworks.ai"
    private let signIn = "imposta FIREWORKS_API_KEY o esegui `firectl set-api-key`"

    private struct Failure: Error {
        var response: Kit.Response?
        var message: String?
    }

    func fetch(previous: AgentUsage?) -> AgentUsage? {
        let settings = PrepaidKit.settings(id)
        let authPath = Kit.expand(Kit.env("FIREWORKS_AUTH_PATH") ?? "~/.fireworks/auth.ini")
        let file = readAuthFile(authPath)
        guard let key = Kit.env("FIREWORKS_API_KEY") ?? file.key
            ?? PrepaidKit.authKey(PrepaidKit.piAuth, "fireworks", onlyAPIKeys: true)
            ?? PrepaidKit.authKey(PrepaidKit.opencodeAuth, "fireworks-ai") else { return nil }
        var accountID = (Kit.env("FIREWORKS_ACCOUNT_ID") ?? PrepaidKit.string(settings["accountId"]) ?? file.account)
            .map(normalize)

        var result = PrepaidKit.start(previous)
        do {
            var account: [String: Any] = [:]
            if accountID == nil { (accountID, account) = try discoverAccount(key) }
            guard let accountID else { return result }
            try updateBalance(&result, key: key, accountID: accountID, account: account, settings: settings)
            result.note = nil
            result.fetchedAt = Date()
        } catch let failure as Failure {
            if let response = failure.response {
                result.note = switch response.status {
                case 403: "La chiave Fireworks non può leggere la fatturazione"
                case 404: "Account Fireworks non trovato"
                default: Kit.failureNote(response, provider: "Fireworks", signIn: signIn)
                }
            } else {
                result.note = failure.message ?? "Risposta di Fireworks non valida"
            }
        } catch {
            result.note = "Risposta di Fireworks non valida"
        }
        return result
    }

    private func updateBalance(_ result: inout AgentUsage, key: String, accountID: String,
                               account: [String: Any], settings: [String: Any]) throws {
        let funded = Kit.number(settings["fundedAmount"]) ?? 0
        let path = "/v1/accounts/\(quote(accountID))"
        // :getBalance is permission-gated (no console key passes it yet); 403 falls back to the estimate.
        if let live = try liveBalance(key, path) {
            let remaining = max(0, live)
            result.balance = Kit.money(remaining)
            result.limits = funded > 0
                ? [PrepaidKit.spent(PrepaidKit.creditLabel, spent: max(0, funded - remaining), funded: funded)] : []
            result.extra = nil
            return
        }
        guard funded > 0 else {
            result.balance = nil
            result.limits = []
            result.extra = "Imposta fundedAmount in ~/.config/notchlite/agents/fireworks.json per stimare il credito"
            return
        }
        var start = try fundedAt(settings["fundedAt"])
        if start == nil {
            let details = account.isEmpty ? try request(key, path) : account
            start = Kit.date(details["createTime"])
        }
        guard let start else {
            throw Failure(message: "Imposta fundedAt: la data di creazione dell'account Fireworks non è disponibile")
        }
        let spent = max(0, try spentSince(key, path, start: start, end: Date()))
        result.balance = "\(Kit.money(max(0, funded - spent))) (stima)"
        result.limits = [PrepaidKit.spent(PrepaidKit.creditLabel, spent: spent, funded: funded)]
        result.extra = nil
    }

    private func liveBalance(_ key: String, _ path: String) throws -> Double? {
        let payload: [String: Any]
        do { payload = try request(key, path + ":getBalance") } catch let failure as Failure where failure.response?.status == 403 {
            return nil
        }
        let candidates: [Any?] = [payload] + ["balance", "creditBalance", "prepaidBalance", "amount"].map { payload[$0] }
        for case let value as [String: Any] in candidates where value["units"] != nil || value["nanos"] != nil {
            guard let amount = money(value) else { throw Failure(message: "Saldo Fireworks illeggibile") }
            return amount
        }
        return nil
    }

    private func spentSince(_ key: String, _ path: String, start: Date, end: Date) throws -> Double {
        let iso = ISO8601DateFormatter()
        do {
            let payload = try request(key, path + "/usageCosts:query", body: [
                "startTime": iso.string(from: start), "endTime": iso.string(from: end), "scope": "ACCOUNT",
            ])
            guard let subtotal = money(payload["subtotal"]) else { throw Failure(message: "Fireworks non ha restituito i costi") }
            return subtotal
        } catch {
            // Older accounts: the billing summary's line items, up to the end of today (UTC).
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let summaryEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
            let payload = try request(key, path + "/billing/summary",
                                      query: ["startTime": iso.string(from: start), "endTime": iso.string(from: summaryEnd)])
            let lineItems = payload["lineItems"] ?? [Any]()
            guard let items = lineItems as? [Any] else { throw Failure(message: nil) }
            return items.compactMap { ($0 as? [String: Any]).flatMap { money($0["totalCost"]) ?? 0 } }.reduce(0, +)
        }
    }

    private func discoverAccount(_ key: String) throws -> (String, [String: Any]) {
        let payload = try request(key, "/v1/accounts", query: ["pageSize": "100"])
        guard let accounts = (payload["accounts"] ?? [Any]()) as? [Any] else { throw Failure(message: nil) }
        let objects = accounts.compactMap { $0 as? [String: Any] }
        guard objects.count == 1 else {
            throw Failure(message: objects.isEmpty ? "Nessun account Fireworks per questa chiave"
                : "Imposta accountId in ~/.config/notchlite/agents/fireworks.json (la chiave vede più account)")
        }
        return (normalize(objects[0]["name"] as? String ?? ""), objects[0])
    }

    private func request(_ key: String, _ path: String, query: [String: String] = [:],
                         body: [String: Any]? = nil) throws -> [String: Any] {
        var components = URLComponents(string: api)!
        components.percentEncodedPath = path
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw Failure(message: nil) }
        var headers = PrepaidKit.header(key)
        headers["Content-Type"] = "application/json"
        let response = Kit.request(url, method: body == nil ? "GET" : "POST", headers: headers, json: body, timeout: 15)
        guard response.ok else { throw Failure(response: response) }
        guard let object = response.object else { throw Failure(message: nil) }
        return object
    }

    private func fundedAt(_ value: Any?) throws -> Date? {
        guard let text = PrepaidKit.string(value) else { return nil }
        if text.count == 10 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: text) { return date }
        } else if let date = Kit.date(text) {
            return date
        }
        throw Failure(message: "fundedAt deve essere una data ISO, es. 2026-07-01")
    }

    /// Google-style Money: `units` + `nanos` / 1e9.
    private func money(_ value: Any?) -> Double? {
        guard let object = value as? [String: Any] else { return nil }
        let units = object["units"] == nil ? 0 : Kit.number(object["units"])
        let nanos = object["nanos"] == nil ? 0 : Kit.number(object["nanos"])
        guard let units, let nanos else { return nil }
        return units + nanos / 1_000_000_000
    }

    private func readAuthFile(_ url: URL) -> (key: String?, account: String?) {
        guard let text = Kit.readText(url) else { return (nil, nil) }
        var key: String?, account: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.hasPrefix(";"), !line.hasPrefix("["),
                  let separator = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = PrepaidKit.string(String(line[line.index(after: separator)...]))
            if ["api_key", "api-key"].contains(name) { key = key ?? value }
            if ["account_id", "account-id"].contains(name) { account = account ?? value }
        }
        return (key, account)
    }

    private func normalize(_ id: String) -> String {
        var text = id.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("accounts/") { text.removeFirst(9) }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func quote(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? id
    }
}

// MARK: Kimchi

struct KimchiCollector: UsageCollector {
    let id = "kimchi"
    let displayName = "Kimchi"
    let symbol = "leaf"
    private let regions = ["us": "https://llm.kimchi.dev", "eu": "https://llm.eu.kimchi.dev"]
    private let signIn = "accedi di nuovo con la CLI di Kimchi o aggiorna KIMCHI_API_KEY"

    func fetch(previous: AgentUsage?) -> AgentUsage? {
        // Kimchi reads ~/.config/kimchi directly, not $XDG_CONFIG_HOME.
        let config = Kit.readJSON(Kit.home.appendingPathComponent(".config/kimchi/config.json")) ?? [:]
        guard let key = Kit.env("KIMCHI_API_KEY") ?? PrepaidKit.string(config["apiKey"])
            ?? PrepaidKit.string(config["api_key"]) else { return nil }
        var result = PrepaidKit.start(previous, plan: nil)

        // A self-hosted login without a host has no gateway: its key never goes to the public one.
        guard let base = gateway(config) else {
            result.note = "Kimchi è in modalità self-hosted senza URL: credito non disponibile"
            return result
        }
        guard trusted(base) else {
            result.note = "Il gateway di Kimchi deve usare HTTPS"
            return result
        }

        var failures: [Kit.Response] = []
        var invalid = false
        var outOfCredits = false
        let credits = Kit.request(URL(string: base + "/v1/credits")!, headers: PrepaidKit.header(key), timeout: 8)
        if credits.ok, let data = credits.object, Self.creditFields.contains(where: { data[$0] != nil }) {
            outOfCredits = applyCredits(data, to: &result)
        } else if credits.ok {
            invalid = true
        } else {
            failures.append(credits)
        }
        let budget = Kit.request(URL(string: base + "/v1/budget")!, headers: PrepaidKit.header(key), timeout: 8)
        if budget.ok, let data = budget.object, data.keys.contains("budgets"),
           data["budgets"] is NSNull || data["budgets"] is [Any] {
            result.limits = budgetLimits(data)
        } else if budget.ok {
            invalid = true
        } else {
            failures.append(budget)
        }

        if let refused = failures.first(where: { [401, 403].contains($0.status) }) {
            result.note = Kit.failureNote(refused, provider: "Kimchi", signIn: signIn)
        } else if outOfCredits {
            result.note = PrepaidKit.outOfCredits
        } else if !credits.ok {
            result.note = Kit.failureNote(credits, provider: "Kimchi", signIn: signIn)
        } else if invalid {
            result.note = "Risposta del gateway Kimchi non valida"
        } else {
            result.note = failures.first.map { Kit.failureNote($0, provider: "Kimchi", signIn: signIn) }
        }
        if failures.isEmpty && !invalid { result.fetchedAt = Date() }
        return result
    }

    private static let creditFields = ["serverless", "remaining", "has_credits", "hasCredits", "tier", "tier_name", "tierName"]

    /// Plan and remaining credit; returns whether the account is out of credits.
    private func applyCredits(_ data: [String: Any], to result: inout AgentUsage) -> Bool {
        if (data["serverless"] as? Bool) == false {
            result.plan = nil
            result.balance = nil
            return false
        }
        let tier = ["tier", "tier_name", "tierName"].lazy.compactMap { data[$0] }.first
        result.plan = planLabel(tier as? String ?? "")
        // Only the remaining figure is known, not how much was bought: no funded meter.
        let remaining = usd(data["remaining"])
        result.balance = remaining.flatMap { $0 >= 0 ? Kit.money($0) : nil }
        let hasCredits = (data["has_credits"] ?? data["hasCredits"]) as? Bool
        return hasCredits == false || (remaining.map { $0 <= 0 } ?? false)
    }

    private func budgetLimits(_ data: [String: Any]) -> [UsageLimit] {
        let period = data["period"] as? [String: Any] ?? [:]
        let end = Kit.date(period["endTime"])
        var title = ""
        if let start = Kit.date(period["startTime"]), let end {
            let days = Int(end.timeIntervalSince(start) / 86_400)
            title = (27...31).contains(days) ? " mensile" : days == 7 ? " settimanale" : ""
        }
        let labels = ["API_KEY": "Budget chiave API", "USER": "Budget", "TEAM_PER_USER": "Budget team",
                      "TEAM_POOLED": "Pool team", "ORGANIZATION_SOFT": "Budget organizzazione",
                      "ORGANIZATION_HARD": "Budget organizzazione"]
        let budgets = (data["budgets"] as? [Any] ?? []).compactMap { raw -> ([String: Any], Double)? in
            guard let entry = raw as? [String: Any], let cap = usd(entry["budgetLimitUsd"]), cap > 0,
                  let spent = usd(entry["totalSpendUsd"]) else { return nil }
            return (entry, spent / cap)
        }
        let shared = budgets.count > 1
        var limits: [UsageLimit] = []
        func add(_ label: String, _ share: Double) {
            guard !limits.contains(where: { $0.label == label }) else { return }
            limits.append(UsageLimit(label: label, percent: Kit.clamp(share), resetsAt: end))
        }
        for (entry, share) in budgets {
            let label = labels[entry["scope"] as? String ?? ""] ?? "Budget"
            add(label + title, share)
            // A provider capped inside the budget is its own allowance on the same clock.
            for case let provider as [String: Any] in entry["providerBudgets"] as? [Any] ?? [] {
                guard (provider["limitType"] as? String ?? "").hasSuffix("CAPPED"),
                      let cap = usd(provider["budgetLimitUsd"]), cap > 0, let used = usd(provider["usageUsd"]),
                      let name = PrepaidKit.string(provider["provider"]) else { continue }
                add("Budget \(Kit.capitalized(name))" + (shared ? " (\(label))" : title), used / cap)
            }
        }
        return limits
    }

    /// The gateway Kimchi itself would use, or nil for a self-hosted login without a host.
    private func gateway(_ config: [String: Any]) -> String? {
        var base = Kit.env("KIMCHI_BASE_URL") ?? ""
        let region = [Kit.env("KIMCHI_REGION"), PrepaidKit.string(config["region"])].compactMap { $0?.lowercased() }
            .first { regions[$0] != nil || $0 == "self-hosted" } ?? "us"
        if base.isEmpty, region == "self-hosted" {
            guard let host = Kit.env("KIMCHI_SELF_HOSTED_URL") ?? PrepaidKit.string(config["selfHostedUrl"]) else { return nil }
            base = host.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/llm"
        }
        if base.isEmpty { base = PrepaidKit.string(config["llmEndpoint"]) ?? regions[region] ?? regions["us"]! }
        base = base.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        if base.lowercased().hasSuffix("/openai/v1") { base.removeLast(10) }
        return base
    }

    /// HTTPS (plain HTTP only to loopback) and no credentials in the URL.
    private func trusted(_ base: String) -> Bool {
        guard let url = URL(string: base), let host = url.host, url.user == nil, url.password == nil,
              URL(string: base + "/v1/credits") != nil else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
        default: return false
        }
    }

    private func planLabel(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
        if ["community", "free", "free-tier", "free-slow"].contains(text) { return "Community" }
        if ["starter", "individual"].contains(text) { return "Coder" }
        if text == "team" { return "Teams" }
        for plan in ["coder", "teams", "enterprise"] where text == plan || text.hasPrefix(plan + "-") {
            return Kit.capitalized(plan)
        }
        return PrepaidKit.string(raw)
    }

    /// Kimchi sends dollar amounts as strings, sometimes with a sign or unit.
    private func usd(_ value: Any?) -> Double? {
        if let text = value as? String {
            let cleaned = text.lowercased().replacingOccurrences(of: "$", with: "").replacingOccurrences(of: "usd", with: "")
                .replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
            return Double(cleaned).flatMap { $0.isFinite ? $0 : nil }
        }
        return Kit.number(value)
    }
}
