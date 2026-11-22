import Foundation

@main
struct ServerTelemetryTests {
    static func main() {
        // 1. Base URL normalization
        let u1 = URL(string: "http://100.117.213.82:8000/v1/models")!
        let u2 = URL(string: "http://100.117.213.82:8080/health")!
        let u3 = URL(string: "http://100.117.213.82:8888/v1")!
        precondition(ServerTelemetryParser.baseURL(from: u1).absoluteString == "http://100.117.213.82:8000")
        precondition(ServerTelemetryParser.baseURL(from: u2).absoluteString == "http://100.117.213.82:8080")
        precondition(ServerTelemetryParser.baseURL(from: u3).absoluteString == "http://100.117.213.82:8888")

        // 2. Real TensorFold /health + /metrics payloads
        let tfHealth = Data("""
        {
          "status": "ok",
          "model": "Qwen3.8-Flash-Next",
          "model_ids": ["Qwen3.8-Flash-Next"],
          "max_batch_size": 5,
          "warming": false,
          "memory": {"active": 81522473376, "cache": 0, "peak": 81522473376},
          "live": {"connections": 2, "waiting": 1, "decode_tokens_per_second": 46.8, "prefill_tokens_per_second": 210.0},
          "version": "1.1.4",
          "backend": "cuda",
          "device": "NVIDIA GB10"
        }
        """.utf8)
        let tfMetrics = """
        # HELP tensorfold:requests_running Running requests
        tensorfold:requests_running 2
        tensorfold:requests_waiting 1
        tensorfold:prompt_tokens_total 12500
        tensorfold:generation_tokens_total 4300
        tensorfold:kv_cache_usage_ratio{pool="0"} 0.37
        """
        let h = ServerTelemetryParser.parseHealthJSON(tfHealth)!
        let m = ServerTelemetryParser.parseMetricsText(tfMetrics)!
        let merged = ServerTelemetryParser.merge([h, m], previous: nil, elapsed: nil)
        precondition(merged.model == "Qwen3.8-Flash-Next")
        precondition(merged.device == "NVIDIA GB10")
        precondition(merged.maxBatchSize == 5)
        precondition(merged.activeRequests == 2)
        precondition(merged.waitingRequests == 1)
        precondition(abs((merged.decodeTokensPerSecond ?? 0) - 46.8) < 0.01)
        precondition(abs((merged.kvCacheRatio ?? 0) - 0.37) < 0.001)
        precondition(merged.totalTokens == 16800)
        precondition(merged.isBusy == true)
        precondition(merged.usageMeter?.label == "KV cache")

        // 3. vLLM Prometheus + delta tok/s derivation
        let vllmPrev = ServerTelemetryParser.parseMetricsText("""
        vllm:num_requests_running 1
        vllm:num_requests_waiting 0
        vllm:kv_cache_usage_perc 0.42
        vllm:generation_tokens_total 1000
        """)!
        let vllmNow = ServerTelemetryParser.parseMetricsText("""
        vllm:num_requests_running 1
        vllm:num_requests_waiting 0
        vllm:kv_cache_usage_perc 0.45
        vllm:generation_tokens_total 1120
        """)!
        let vllmMerged = ServerTelemetryParser.merge([vllmNow], previous: vllmPrev, elapsed: 2.0)
        precondition(abs((vllmMerged.decodeTokensPerSecond ?? 0) - 60.0) < 0.01)
        precondition(abs((vllmMerged.kvCacheRatio ?? 0) - 0.45) < 0.001)

        // 4. llama.cpp /slots
        let slotsData = Data("""
        [
          {"id": 0, "is_processing": true, "timings": {"predicted_per_second": 32.5}},
          {"id": 1, "is_processing": false}
        ]
        """.utf8)
        let slots = ServerTelemetryParser.parseSlotsJSON(slotsData)!
        precondition(slots.activeRequests == 1 && slots.maxBatchSize == 2)
        precondition(slots.usageMeter?.label == "Slot attivi")
        precondition(abs((slots.usageMeter?.percent ?? 0) - 0.5) < 0.001)

        // 5. Ollama /api/ps & OpenAI /v1/models
        let ollamaData = Data("""
        {"models": [{"name": "qwen3:32b", "size_vram": 21474836480}]}
        """.utf8)
        let ollama = ServerTelemetryParser.parseOllamaPSJSON(ollamaData)!
        precondition(ollama.model == "qwen3:32b" && ollama.memoryUsedBytes == 21_474_836_480)

        let modelsData = Data("""
        {"object": "list", "data": [{"id": "deepseek-r1"}]}
        """.utf8)
        precondition(ServerTelemetryParser.parseModelsJSON(modelsData) == "deepseek-r1")

        // 6. ComfyUI MiniMax H3 (/system_stats + /queue + SSH probe output)
        let comfyStats = """
        {"system": {"os": "linux"}, "devices": [{"name": "cuda:0 NVIDIA GB10 : cudaMallocAsync", "type": "cuda", "vram_total": 130659606528, "vram_free": 44523459718}]}
        """
        let comfyQueue = """
        {"queue_running": [[1, "job-1", {"1": {"class_type": "UNETLoader", "inputs": {"unet_name": "minimax_h3_fl2va_pruned_int8_convrot.safetensors"}}}]], "queue_pending": []}
        """
        let sshOut = "<<<COMFY_STATS>>>\n\(comfyStats)\n<<<COMFY_QUEUE>>>\n\(comfyQueue)\n"
        let sshParsed = ServerTelemetryParser.parseSSHProbeOutput(sshOut)
        precondition(sshParsed.isUp)
        let comfyMerged = ServerTelemetryParser.merge(sshParsed.parts, previous: nil, elapsed: nil)
        precondition(comfyMerged.backend == "comfyui")
        precondition(comfyMerged.device == "NVIDIA GB10")
        precondition(comfyMerged.model == "minimax_h3_fl2va_pruned_int8_convrot")
        precondition(comfyMerged.activeRequests == 1 && comfyMerged.waitingRequests == 0)
        precondition(comfyMerged.isBusy == true)
        precondition(comfyMerged.usageMeter?.label == "VRAM")
        precondition((comfyMerged.usageMeter?.percent ?? 0) > 0.65 && (comfyMerged.usageMeter?.percent ?? 0) < 0.67)

        print("Server telemetry checks passed")
    }
}
