// Claude Code and Codex limits, after Omarchy's `claude` and `codex` collectors.
// Their local stats come from StatsIndexer (UsageService.swift).

import Foundation

struct ClaudeCollector: UsageCollector {
    let id = "claude"
    let displayName = "Claude Code"
    let symbol = "asterisk"
    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func fetch(previous: AgentUsage?) -> AgentUsage? {
        guard let credentials = readCredentials() else {
            guard Kit.exists(Kit.home.appendingPathComponent(".claude")) else { return nil }
            return AgentUsage(note: "Accedi a Claude Code per vedere i limiti", fetchedAt: Date())
        }
        var result = previous ?? AgentUsage()
        result.plan = credentials.plan ?? result.plan

        if let expiry = credentials.expiresAt, expiry < Date() {
            result.note = "Limiti in pausa: apri Claude Code per rinnovare l'accesso"
            return result
        }

        let response = Kit.request(endpoint, headers: [
            "Authorization": "Bearer \(credentials.token)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
        ])
        guard response.ok, let object = response.object else {
            result.note = Kit.failureNote(response, provider: "Anthropic", signIn: "apri Claude Code o esegui `claude auth login`")
            return result
        }
        let limits = parse(object)
        if limits.isEmpty {
            result.note = "Anthropic non ha restituito limiti"
        } else {
            result.limits = limits
            result.note = nil
            result.fetchedAt = Date()
        }
        return result
    }

    private func parse(_ object: [String: Any]) -> [UsageLimit] {
        var limits: [UsageLimit] = []
        func add(_ key: String, _ label: String, hours: Double) {
            guard let bucket = object[key] as? [String: Any],
                  let utilization = Kit.number(bucket["utilization"]) else { return }
            limits.append(Kit.limit(label, used: utilization / 100, resetsAt: bucket["resets_at"], window: hours * 3600))
        }
        add("five_hour", "Sessione (5 ore)", hours: 5)
        add("seven_day", "Settimana", hours: 168)

        // Model-scoped allowances only appear in the `limits` array.
        var seen = Set<String>()
        for entry in object["limits"] as? [[String: Any]] ?? [] {
            guard let scope = entry["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = (model["display_name"] ?? model["id"]) as? String, !name.isEmpty,
                  let percent = Kit.number(entry["percent"]) else { continue }
            let kind = (entry["kind"] as? String ?? "").lowercased()
            let window = kind.contains("week") || kind.contains("day") ? "settimana"
                : kind.contains("hour") || kind.contains("session") ? "sessione" : ""
            let label = window.isEmpty ? name : "\(name) · \(window)"
            guard seen.insert(label).inserted else { continue }
            let hours: Double? = window == "settimana" ? 168 : window == "sessione" ? 5 : nil
            limits.append(Kit.limit(label, used: percent / 100, resetsAt: entry["resets_at"], window: hours.map { $0 * 3600 }))
        }
        return limits
    }

    private func readCredentials() -> (token: String, expiresAt: Date?, plan: String?)? {
        // Recent Claude Code builds keep the sign-in in the login Keychain;
        // older ones in ~/.claude/.credentials.json.
        var data = Kit.keychain(service: "Claude Code-credentials").map { Data($0.utf8) }
        if data == nil {
            data = try? Data(contentsOf: Kit.home.appendingPathComponent(".claude/.credentials.json"))
        }
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expires = Kit.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return (token, expires, planName(oauth))
    }

    private func planName(_ oauth: [String: Any]) -> String? {
        guard let type = oauth["subscriptionType"] as? String, !type.isEmpty else { return nil }
        var name = Kit.capitalized(type)
        let tier = oauth["rateLimitTier"] as? String ?? ""
        if let match = tier.range(of: #"(\d+)x"#, options: .regularExpression) {
            name += " " + tier[match]
        }
        return name
    }
}

struct CodexCollector: UsageCollector {
    let id = "codex"
    let displayName = "Codex"
    let symbol = "chevron.left.forwardslash.chevron.right"

    private var home: URL {
        Kit.env("CODEX_HOME").map { URL(fileURLWithPath: $0) } ?? Kit.home.appendingPathComponent(".codex")
    }

    private func binary() -> String? {
        Kit.which("codex") ?? [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func fetch(previous: AgentUsage?) -> AgentUsage? {
        guard Kit.exists(home) else { return nil }
        var result = previous ?? AgentUsage()
        guard let auth = Kit.readJSON(home.appendingPathComponent("auth.json")) else {
            result.note = "Esegui `codex login` per vedere i limiti"
            return result
        }
        if auth["auth_mode"] as? String == "apikey" {
            result.note = "Accesso con API key: nessun limite di piano"
            return result
        }
        guard let codex = binary() else {
            result.note = "CLI di Codex non trovata"
            return result
        }

        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"notchlite","version":"1"}}}"#,
            #"{"method":"initialized","params":{}}"#,
            #"{"id":2,"method":"account/rateLimits/read","params":{}}"#,
        ]
        guard let reply = Kit.jsonRPC(
            executable: codex, arguments: ["-s", "read-only", "-a", "on-request", "app-server"],
            lines: requests, awaitID: 2, timeout: 12
        ) else {
            result.note = "Codex non ha risposto, riprovo più tardi"
            return result
        }
        guard let payload = reply["result"] as? [String: Any] else {
            let message = (reply["error"] as? [String: Any])?["message"] as? String
            result.note = "Codex: \(message ?? "risposta senza limiti")"
            return result
        }

        var buckets: [(String, [String: Any])] = []
        if let byID = payload["rateLimitsByLimitId"] as? [String: Any] {
            buckets = byID.compactMap { key, value in (value as? [String: Any]).map { (key, $0) } }
                .sorted { ($0.0 != "codex" ? 1 : 0, $0.0) < ($1.0 != "codex" ? 1 : 0, $1.0) }
        } else if let legacy = payload["rateLimits"] as? [String: Any] {
            buckets = [("codex", legacy)]
        }

        var limits: [UsageLimit] = []
        var plan: String?
        for (limitID, bucket) in buckets {
            plan = plan ?? (bucket["planType"] as? String)
            let general = limitID == "codex" || buckets.count == 1
            let name = (bucket["limitName"] as? String) ?? limitID
            for key in ["primary", "secondary"] {
                guard let window = bucket[key] as? [String: Any],
                      let used = Kit.number(window["usedPercent"]) else { continue }
                let minutes = Int(Kit.number(window["windowDurationMins"]) ?? 0)
                let span = minutes >= 28 * 1440 ? "Mese" : minutes >= 1440 ? "Settimana"
                    : minutes > 0 ? "Sessione (\(minutes % 60 == 0 ? "\(minutes / 60) ore" : "\(minutes) min"))" : "Limite"
                let reset = Kit.number(window["resetsAt"]).flatMap { $0 > 0 ? $0 : nil }
                limits.append(Kit.limit(general ? span : "\(name) · \(span.lowercased())", used: used / 100,
                                        resetsAt: reset, window: minutes > 0 ? Double(minutes) * 60 : nil))
            }
            if let cap = bucket["individualLimit"] as? [String: Any],
               let capValue = Kit.number(cap["limit"]), capValue > 0, let spent = Kit.number(cap["used"]) {
                limits.append(Kit.limit("Limite di spesa", used: spent / capValue, resetsAt: cap["resetsAt"]))
            }
        }

        let resets = (payload["rateLimitResetCredits"] as? [String: Any]).flatMap { Kit.number($0["availableCount"]) } ?? 0
        result.extra = resets > 0 ? "\(Int(resets)) reset gratuit\(resets == 1 ? "o" : "i") disponibil\(resets == 1 ? "e" : "i")" : nil
        result.plan = plan.map(planName) ?? result.plan
        if limits.isEmpty {
            result.note = "Codex non ha restituito limiti"
        } else {
            result.limits = limits
            result.note = nil
            result.fetchedAt = Date()
        }
        return result
    }

    private func planName(_ raw: String) -> String {
        switch raw {
        case "pro": "Pro"
        case "promax": "Pro 500"
        case "plus": "Plus"
        case "team": "Business"
        case "enterprise": "Enterprise"
        case "free": "Free"
        default: Kit.capitalized(raw)
        }
    }
}
