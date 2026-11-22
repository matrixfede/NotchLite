import Foundation

/// Live telemetry collected from a local LLM server (TensorFold, vLLM,
/// llama.cpp / llama-server, SGLang, Ollama, or OpenAI-compatible endpoints).
struct ServerTelemetry: Equatable {
    var model: String?
    var device: String?
    var backend: String?
    var warming: Bool = false
    var activeRequests: Int?
    var waitingRequests: Int?
    var maxBatchSize: Int?
    var decodeTokensPerSecond: Double?
    var prefillTokensPerSecond: Double?
    var kvCacheRatio: Double?
    var memoryUsedBytes: UInt64?
    var memoryTotalBytes: UInt64?
    var promptTokensTotal: Int?
    var generationTokensTotal: Int?
    var latencyMs: Int?

    var isBusy: Bool {
        (activeRequests ?? 0) > 0
            || (waitingRequests ?? 0) > 0
            || (decodeTokensPerSecond ?? 0) > 0.1
            || (prefillTokensPerSecond ?? 0) > 0.1
    }

    var totalTokens: Int? {
        guard promptTokensTotal != nil || generationTokensTotal != nil else { return nil }
        return (promptTokensTotal ?? 0) + (generationTokensTotal ?? 0)
    }

    /// Primary real-time utilization meter to display in the Agenti tab.
    var usageMeter: (label: String, percent: Double)? {
        if let kv = kvCacheRatio, kv.isFinite {
            return ("KV cache", min(max(kv, 0), 1))
        }
        if let used = memoryUsedBytes, let total = memoryTotalBytes, total > 0 {
            return ("VRAM", min(max(Double(used) / Double(total), 0), 1))
        }
        if let active = activeRequests, let maxBatch = maxBatchSize, maxBatch > 0 {
            return ("Slot attivi", min(max(Double(active) / Double(maxBatch), 0), 1))
        }
        return nil
    }
}

enum ServerTelemetryParser {
    /// Extracts `scheme://host[:port]` from any configured endpoint such as
    /// `http://100.117.213.82:8000/v1/models` or `http://host:8080/health`.
    static func baseURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    /// Parses `/health` JSON from TensorFold or llama.cpp.
    static func parseHealthJSON(_ data: Data) -> ServerTelemetry? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var t = ServerTelemetry()
        if let model = nonEmptyString(object["model"]) {
            t.model = model
        } else if let models = object["model_ids"] as? [String], let first = models.first, !first.isEmpty {
            t.model = first
        }
        t.device = nonEmptyString(object["device"])
        t.backend = nonEmptyString(object["backend"])
        if let warming = object["warming"] as? Bool { t.warming = warming }
        if let status = nonEmptyString(object["status"])?.lowercased(),
           status == "loading model" || status == "warming" || status == "starting" {
            t.warming = true
        }
        if let maxBatch = intValue(object["max_batch_size"]) { t.maxBatchSize = maxBatch }

        if let memory = object["memory"] as? [String: Any],
           let active = uint64Value(memory["active"]), active > 0 {
            t.memoryUsedBytes = active
        }

        if let live = object["live"] as? [String: Any] {
            if let conn = intValue(live["connections"]) { t.activeRequests = conn }
            if let wait = intValue(live["waiting"]) { t.waitingRequests = wait }
            if let dec = doubleValue(live["decode_tokens_per_second"]) { t.decodeTokensPerSecond = dec }
            if let pre = doubleValue(live["prefill_tokens_per_second"]) { t.prefillTokensPerSecond = pre }
        }

        // llama-server /health optional fields
        if let processing = intValue(object["slots_processing"]) { t.activeRequests = processing }
        if let idle = intValue(object["slots_idle"]), let processing = t.activeRequests {
            t.maxBatchSize = processing + idle
        }
        return t
    }

    /// Parses Prometheus `/metrics` from TensorFold, vLLM, llama.cpp, or SGLang.
    static func parseMetricsText(_ text: String) -> ServerTelemetry? {
        var t = ServerTelemetry()
        var found = false
        var kvMax: Double?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let (name, value) = parsePrometheusLine(line) else { continue }

            switch name {
            // Active / running requests
            case "tensorfold:requests_running",
                 "vllm:num_requests_running",
                 "llamacpp:requests_processing",
                 "sglang:num_running_reqs":
                t.activeRequests = (t.activeRequests ?? 0) + Int(value.rounded())
                found = true

            // Waiting / queued requests
            case "tensorfold:requests_waiting",
                 "vllm:num_requests_waiting",
                 "llamacpp:requests_deferred",
                 "sglang:num_queue_reqs":
                t.waitingRequests = (t.waitingRequests ?? 0) + Int(value.rounded())
                found = true

            // KV cache utilization ratio (0...1, or 0...100 if > 1)
            case "tensorfold:kv_cache_usage_ratio",
                 "vllm:kv_cache_usage_perc",
                 "vllm:gpu_cache_usage_perc",
                 "llamacpp:kv_cache_usage_ratio",
                 "sglang:token_usage":
                let normalized = value > 1.0 ? value / 100.0 : value
                kvMax = max(kvMax ?? 0, min(max(normalized, 0), 1))
                found = true

            // Live generation throughput (tok/s)
            case "llamacpp:predicted_tokens_seconds",
                 "sglang:gen_throughput":
                t.decodeTokensPerSecond = value
                found = true

            // Cumulative prompt tokens
            case "tensorfold:prompt_tokens_total",
                 "vllm:prompt_tokens_total",
                 "llamacpp:prompt_tokens_total":
                t.promptTokensTotal = (t.promptTokensTotal ?? 0) + Int(value.rounded())
                found = true

            // Cumulative generated tokens
            case "tensorfold:generation_tokens_total",
                 "vllm:generation_tokens_total",
                 "llamacpp:tokens_predicted_total":
                t.generationTokensTotal = (t.generationTokensTotal ?? 0) + Int(value.rounded())
                found = true

            default:
                break
            }
        }

        if let kvMax { t.kvCacheRatio = kvMax }
        return found ? t : nil
    }

    /// Parses OpenAI-compatible `/v1/models` and returns the first loaded model ID.
    static func parseModelsJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return nil }
        for item in list {
            if let id = nonEmptyString(item["id"]) { return id }
        }
        return nil
    }

    /// Parses llama.cpp `/slots` JSON array.
    static func parseSlotsJSON(_ data: Data) -> ServerTelemetry? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !list.isEmpty else { return nil }
        var active = 0
        var tps: Double?
        for slot in list {
            let processing = (slot["is_processing"] as? Bool == true) || (intValue(slot["state"]) ?? 0) > 0
            if processing { active += 1 }
            if let timings = slot["timings"] as? [String: Any],
               let predicted = doubleValue(timings["predicted_per_second"]), predicted > 0 {
                tps = max(tps ?? 0, predicted)
            }
        }
        var t = ServerTelemetry()
        t.activeRequests = active
        t.maxBatchSize = list.count
        t.decodeTokensPerSecond = tps
        return t
    }

    /// Parses Ollama `/api/ps` JSON.
    static func parseOllamaPSJSON(_ data: Data) -> ServerTelemetry? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return nil }
        var t = ServerTelemetry()
        if let first = models.first {
            t.model = nonEmptyString(first["name"]) ?? nonEmptyString(first["model"])
        }
        let vram = models.reduce(UInt64(0)) { $0 + (uint64Value($1["size_vram"]) ?? 0) }
        if vram > 0 { t.memoryUsedBytes = vram }
        t.backend = "ollama"
        return t
    }

    /// Parses ComfyUI `/system_stats` JSON (e.g. MiniMax H3 / video generation).
    static func parseComfySystemStatsJSON(_ data: Data) -> ServerTelemetry? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["system"] is [String: Any] else { return nil }
        var t = ServerTelemetry()
        t.backend = "comfyui"
        if let devices = object["devices"] as? [[String: Any]], let gpu = devices.first {
            if let rawName = nonEmptyString(gpu["name"]) {
                t.device = cleanDeviceName(rawName)
            }
            if let total = uint64Value(gpu["vram_total"]), total > 0 {
                t.memoryTotalBytes = total
                if let free = uint64Value(gpu["vram_free"]) {
                    t.memoryUsedBytes = total > free ? total - free : 0
                }
            }
        }
        return t
    }

    /// Parses ComfyUI `/queue` JSON for running/pending jobs and active model name.
    static func parseComfyQueueJSON(_ data: Data) -> ServerTelemetry? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["queue_running"] != nil || object["queue_pending"] != nil else { return nil }
        var t = ServerTelemetry()
        t.backend = "comfyui"
        let running = object["queue_running"] as? [Any] ?? []
        let pending = object["queue_pending"] as? [Any] ?? []
        t.activeRequests = running.count
        t.waitingRequests = pending.count
        t.model = extractComfyModel(from: running) ?? extractComfyModel(from: pending)
        return t
    }

    /// Parses the delimited output of a single SSH loopback probe command.
    static func parseSSHProbeOutput(_ text: String) -> (isUp: Bool, parts: [ServerTelemetry]) {
        var sections: [String: String] = [:]
        var current: String?
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.hasPrefix("<<<") && line.hasSuffix(">>>") {
                current = String(line.dropFirst(3).dropLast(3))
                sections[current!] = ""
            } else if let key = current {
                if !sections[key]!.isEmpty { sections[key]! += "\n" }
                sections[key]! += line
            }
        }

        var parts: [ServerTelemetry] = []
        var isUp = false
        if let raw = sections["COMFY_STATS"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
           let parsed = parseComfySystemStatsJSON(Data(raw.utf8)) {
            parts.append(parsed)
            isUp = true
        }
        if let raw = sections["COMFY_QUEUE"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
           let parsed = parseComfyQueueJSON(Data(raw.utf8)) {
            parts.append(parsed)
            isUp = true
        }
        if let raw = sections["HEALTH"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            isUp = true
            if let parsed = parseHealthJSON(Data(raw.utf8)) { parts.append(parsed) }
        }
        if let raw = sections["METRICS"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
           let parsed = parseMetricsText(raw) {
            parts.append(parsed)
            isUp = true
        }
        if let raw = sections["MODELS"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            isUp = true
            if let model = parseModelsJSON(Data(raw.utf8)) {
                var m = ServerTelemetry(); m.model = model; parts.append(m)
            }
        }
        return (isUp, parts)
    }

    private static func cleanDeviceName(_ raw: String) -> String {
        var name = raw
        if let colonSpace = name.range(of: " : ") {
            name = String(name[..<colonSpace.lowerBound])
        }
        if name.lowercased().hasPrefix("cuda:"), let space = name.firstIndex(of: " ") {
            name = String(name[name.index(after: space)...])
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractComfyModel(from queueItems: [Any]) -> String? {
        let preferredKeys = ["unet_name", "ckpt_name", "model_name", "diffusion_model"]
        for entry in queueItems {
            guard let tuple = entry as? [Any], tuple.count > 2,
                  let prompt = tuple[2] as? [String: Any] else { continue }
            for key in preferredKeys {
                for nodeValue in prompt.values {
                    guard let node = nodeValue as? [String: Any],
                          let inputs = node["inputs"] as? [String: Any],
                          let raw = nonEmptyString(inputs[key]) else { continue }
                    return stripModelExtension(raw)
                }
            }
        }
        return nil
    }

    private static func stripModelExtension(_ filename: String) -> String {
        let base = (filename as NSString).lastPathComponent
        for ext in [".safetensors", ".gguf", ".ckpt", ".pt", ".pth", ".bin"] {
            if base.lowercased().hasSuffix(ext) {
                return String(base.dropLast(ext.count))
            }
        }
        return base
    }

    /// Combines telemetry snapshots from multiple endpoints (earlier entries take
    /// precedence on overlapping fields) and computes live tok/s from cumulative
    /// token counters when no direct throughput metric is reported.
    static func merge(_ parts: [ServerTelemetry], previous: ServerTelemetry?, elapsed: TimeInterval?) -> ServerTelemetry {
        var result = ServerTelemetry()
        for part in parts {
            if result.model == nil { result.model = part.model }
            if result.device == nil { result.device = part.device }
            if result.backend == nil { result.backend = part.backend }
            if part.warming { result.warming = true }
            if result.activeRequests == nil { result.activeRequests = part.activeRequests }
            if result.waitingRequests == nil { result.waitingRequests = part.waitingRequests }
            if result.maxBatchSize == nil { result.maxBatchSize = part.maxBatchSize }
            if result.decodeTokensPerSecond == nil { result.decodeTokensPerSecond = part.decodeTokensPerSecond }
            if result.prefillTokensPerSecond == nil { result.prefillTokensPerSecond = part.prefillTokensPerSecond }
            if result.kvCacheRatio == nil { result.kvCacheRatio = part.kvCacheRatio }
            if result.memoryUsedBytes == nil { result.memoryUsedBytes = part.memoryUsedBytes }
            if result.memoryTotalBytes == nil { result.memoryTotalBytes = part.memoryTotalBytes }
            if result.promptTokensTotal == nil { result.promptTokensTotal = part.promptTokensTotal }
            if result.generationTokensTotal == nil { result.generationTokensTotal = part.generationTokensTotal }
            if result.latencyMs == nil { result.latencyMs = part.latencyMs }
        }

        // Derive live tok/s from cumulative generation tokens if the server didn't report it directly.
        if (result.decodeTokensPerSecond == nil || result.decodeTokensPerSecond == 0),
           let nowGen = result.generationTokensTotal,
           let prevGen = previous?.generationTokensTotal,
           let elapsed, elapsed >= 0.3, elapsed <= 30,
           nowGen > prevGen {
            result.decodeTokensPerSecond = Double(nowGen - prevGen) / elapsed
        }
        return result
    }

    private static func parsePrometheusLine(_ line: String) -> (String, Double)? {
        // Format: `metric_name{label="val"} 123.45 [timestamp]` or `metric_name 123.45`
        var index = line.startIndex
        var nameEnd = index
        var inBraces = false
        while index < line.endIndex {
            let ch = line[index]
            if ch == "{" && !inBraces {
                nameEnd = index
                inBraces = true
            } else if ch == "}" && inBraces {
                inBraces = false
            } else if ch.isWhitespace && !inBraces {
                if nameEnd == line.startIndex { nameEnd = index }
                break
            }
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return nil }
        let metricName = String(line[line.startIndex..<nameEnd])
        guard !metricName.isEmpty else { return nil }
        let rest = line[index...].trimmingCharacters(in: .whitespaces)
        guard let valueToken = rest.split(whereSeparator: \.isWhitespace).first,
              let value = Double(valueToken), value.isFinite else { return nil }
        return (metricName, value)
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intValue(_ raw: Any?) -> Int? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.intValue
    }

    private static func uint64Value(_ raw: Any?) -> UInt64? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue >= 0 else { return nil }
        return n.uint64Value
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
}
