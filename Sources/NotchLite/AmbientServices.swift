import AppKit
import CoreAudio
import CoreMediaIO
import EventKit
import Network

/// The small ambient services, owned together.
@MainActor
final class Ambient {
    let servers = ServerMonitor()
    let privacy = PrivacyMonitor()
    let calendar = CalendarService()
    let shelf = Shelf()
    let network = NetworkService()
    let system = SystemStats()
    let timer = TimerService()
}

// MARK: File shelf

/// Files parked on the notch: drop them on the island, drag them out later.
/// Only the paths are kept (in the preferences); files gone missing drop out.
@MainActor
final class Shelf: ObservableObject {
    @Published private(set) var files: [URL] = []
    private static let key = "shelf"

    init() {
        files = (UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        let new = urls.filter { $0.isFileURL && !files.contains($0) }
        guard !new.isEmpty else { return }
        files.append(contentsOf: new)
        save()
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
        save()
    }

    func clear() {
        files.removeAll()
        save()
    }

    private func save() {
        UserDefaults.standard.set(files.map(\.path), forKey: Self.key)
    }
}

// MARK: Local model servers

struct ServerStatus: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let url: URL
    var isUp: Bool?
    var telemetry: ServerTelemetry? = nil
    var checkedAt: Date? = nil

    /// What the Agenti tab shows as the row title: the model the server reports
    /// while it is up, otherwise the label typed when the server was added (the
    /// label belongs to the address and goes stale when another model is loaded).
    var displayName: String {
        if isUp == true, let model = telemetry?.model, !model.isEmpty { return model }
        return name
    }
}

/// Pings the local model servers once a minute (and every 2 seconds while the
/// Agenti tab is open for real-time telemetry: active requests, KV cache, tok/s,
/// loaded model and VRAM). The list is edited from the notch settings.
@MainActor
final class ServerMonitor: ObservableObject {
    @Published private(set) var servers: [ServerStatus] = []

    private struct Capabilities {
        var supportsHealth = true
        var supportsMetrics = true
        var supportsSlots = true
        var supportsOllamaPS = true
        var supportsComfyUI = true
        var cachedModel: String?
    }

    private static let key = "servers"
    private var timer: Timer?
    private var liveTimer: Timer?
    private var path: NWPathMonitor?
    private var checkedAt = Date.distantPast
    private var isChecking = false
    private var isLive = false
    private var capabilities: [String: Capabilities] = [:]

    init() {
        importLegacyFile()
        servers = Self.stored()
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(forceOffline: true) }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let path = NWPathMonitor()
        path.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.check(forceOffline: true) } }
        }
        path.start(queue: .global(qos: .utility))
        self.path = path
        check(forceOffline: true)
    }

    /// Enables 2-second real-time polling while the Agenti tab is visible.
    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        liveTimer?.invalidate()
        liveTimer = nil
        if live {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check(forceOffline: false) }
            }
            timer.tolerance = 0.4
            RunLoop.main.add(timer, forMode: .common)
            self.liveTimer = timer
            check(forceOffline: true)
        }
    }

    func refreshNow() {
        capabilities.removeAll()
        check(forceOffline: true)
    }

    /// The notch opened: refresh unless the last answer is fresh.
    func checkIfStale() {
        if Date().timeIntervalSince(checkedAt) > 15 { check(forceOffline: true) }
    }

    func add(name: String, url: URL) {
        var entries = Self.stored().filter { $0.name != name }
        entries.append(ServerStatus(name: name, url: url, isUp: nil))
        save(entries)
    }

    func remove(_ name: String) {
        save(Self.stored().filter { $0.name != name })
    }

    private func save(_ entries: [ServerStatus]) {
        UserDefaults.standard.set(entries.map { ["name": $0.name, "url": $0.url.absoluteString] }, forKey: Self.key)
        capabilities.removeAll()
        servers = entries
        check(forceOffline: true)
    }

    private func check(forceOffline: Bool) {
        let list = servers
        guard !list.isEmpty, !isChecking else { return }
        isChecking = true
        let now = Date()
        checkedAt = now
        let capsSnapshot = capabilities

        DispatchQueue.global(qos: .utility).async {
            let results = Locked([ServerStatus?](repeating: nil, count: list.count))
            let updatedCaps = Locked(capsSnapshot)

            DispatchQueue.concurrentPerform(iterations: list.count) { index in
                let server = list[index]
                // During 2s live polling, re-check offline servers every 10s so an
                // unreachable host never stalls telemetry for online ones.
                if !forceOffline, server.isUp == false,
                   let last = server.checkedAt, now.timeIntervalSince(last) < 10 {
                    results.mutate { $0[index] = server }
                    return
                }
                let caps = capsSnapshot[server.url.absoluteString] ?? Capabilities()
                let (nextStatus, nextCaps) = Self.probe(server: server, caps: caps, now: now)
                results.mutate { $0[index] = nextStatus }
                updatedCaps.mutate { $0[server.url.absoluteString] = nextCaps }
            }

            let finalResults = results.value.compactMap { $0 }
            let finalCaps = updatedCaps.value
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isChecking = false
                    self.capabilities = finalCaps
                    // Ignore an answer for a list that was edited meanwhile.
                    if finalResults.map(\.name) == self.servers.map(\.name), finalResults != self.servers {
                        self.servers = finalResults
                    }
                }
            }
        }
    }

    private nonisolated static func probe(server: ServerStatus, caps initialCaps: Capabilities, now: Date) -> (ServerStatus, Capabilities) {
        var caps = initialCaps
        if server.url.scheme?.lowercased() == "ssh" {
            return (probeOverSSH(server: server, now: now), caps)
        }
        let base = ServerTelemetryParser.baseURL(from: server.url)
        let started = Date()
        var parts: [ServerTelemetry] = []
        var reached = false

        // 1. Health endpoint (fast status + TensorFold / llama.cpp live JSON)
        if caps.supportsHealth {
            let healthURL = base.appendingPathComponent("health")
            let resp = Kit.request(healthURL, timeout: 2.5)
            if resp.status > 0 {
                reached = true
                if resp.ok, let data = resp.data, let parsed = ServerTelemetryParser.parseHealthJSON(data) {
                    parts.append(parsed)
                } else if resp.status == 404 || resp.status == 405 {
                    caps.supportsHealth = false
                }
            } else {
                // Transport failure (connection refused / timeout): offline.
                return (ServerStatus(name: server.name, url: server.url, isUp: false, telemetry: nil, checkedAt: now), caps)
            }
        }

        // 2. If /health wasn't supported, try ComfyUI /system_stats or the configured URL directly.
        if !reached {
            let resp = Kit.request(server.url, timeout: 2.5)
            if resp.status > 0 {
                reached = true
                if resp.ok, let data = resp.data {
                    if let parsed = ServerTelemetryParser.parseComfySystemStatsJSON(data) { parts.append(parsed) }
                    if let parsed = ServerTelemetryParser.parseHealthJSON(data) { parts.append(parsed) }
                    if let model = ServerTelemetryParser.parseModelsJSON(data) {
                        var m = ServerTelemetry(); m.model = model; parts.append(m)
                    }
                }
            } else {
                return (ServerStatus(name: server.name, url: server.url, isUp: false, telemetry: nil, checkedAt: now), caps)
            }
        }

        let latencyMs = max(1, Int(Date().timeIntervalSince(started) * 1000))

        // 2b. ComfyUI (/system_stats + /queue) when /health isn't present (e.g. port 8188).
        if !caps.supportsHealth, caps.supportsComfyUI {
            let statsResp = Kit.request(base.appendingPathComponent("system_stats"), timeout: 1.5)
            if statsResp.ok, let data = statsResp.data,
               let parsed = ServerTelemetryParser.parseComfySystemStatsJSON(data) {
                parts.append(parsed)
                let queueResp = Kit.request(base.appendingPathComponent("queue"), timeout: 1.5)
                if queueResp.ok, let qData = queueResp.data,
                   let qParsed = ServerTelemetryParser.parseComfyQueueJSON(qData) {
                    parts.append(qParsed)
                }
            } else if statsResp.status == 404 || statsResp.status == 405 {
                caps.supportsComfyUI = false
            }
        }

        let isComfy = parts.contains { $0.backend == "comfyui" }

        // 3. Prometheus /metrics (TensorFold, vLLM, llama.cpp, SGLang)
        if !isComfy, caps.supportsMetrics {
            let resp = Kit.request(base.appendingPathComponent("metrics"), timeout: 1.5)
            if resp.ok, let data = resp.data, let text = String(data: data, encoding: .utf8),
               let parsed = ServerTelemetryParser.parseMetricsText(text) {
                parts.append(parsed)
            } else if resp.status == 404 || resp.status == 405 || resp.status == 403 {
                caps.supportsMetrics = false
            }
        }

        // 4. llama.cpp /slots (only if we don't already have active request counts)
        let hasActiveInfo = parts.contains { $0.activeRequests != nil || $0.kvCacheRatio != nil }
        if !isComfy, !hasActiveInfo, caps.supportsSlots {
            let resp = Kit.request(base.appendingPathComponent("slots"), timeout: 1.5)
            if resp.ok, let data = resp.data, let parsed = ServerTelemetryParser.parseSlotsJSON(data) {
                parts.append(parsed)
            } else if resp.status == 404 || resp.status == 405 || resp.status == 403 {
                caps.supportsSlots = false
            }
        }

        // 5. Ollama /api/ps (only if no model / telemetry yet)
        let hasModel = parts.contains { $0.model != nil }
        if !isComfy, !hasModel && !hasActiveInfo && caps.supportsOllamaPS {
            let resp = Kit.request(base.appendingPathComponent("api/ps"), timeout: 1.5)
            if resp.ok, let data = resp.data, let parsed = ServerTelemetryParser.parseOllamaPSJSON(data) {
                parts.append(parsed)
            } else if resp.status == 404 || resp.status == 405 {
                caps.supportsOllamaPS = false
            }
        }

        // 6. OpenAI-compatible /v1/models (cached once discovered while online)
        if !isComfy, !parts.contains(where: { $0.model != nil }) {
            if let cached = caps.cachedModel {
                var m = ServerTelemetry(); m.model = cached; parts.append(m)
            } else {
                let resp = Kit.request(base.appendingPathComponent("v1/models"), timeout: 1.5)
                if resp.ok, let data = resp.data, let model = ServerTelemetryParser.parseModelsJSON(data) {
                    caps.cachedModel = model
                    var m = ServerTelemetry(); m.model = model; parts.append(m)
                }
            }
        } else if let foundModel = parts.compactMap(\.model).first {
            caps.cachedModel = foundModel
        }

        let elapsed = server.checkedAt.map { now.timeIntervalSince($0) }
        var merged = ServerTelemetryParser.merge(parts, previous: server.telemetry, elapsed: elapsed)
        merged.latencyMs = latencyMs
        return (ServerStatus(name: server.name, url: server.url, isUp: true, telemetry: merged, checkedAt: now), caps)
    }

    /// Probes a remote localhost-bound server (`ssh://user@host:port`) in a single
    /// multiplexed SSH round-trip, supporting ComfyUI, TensorFold, vLLM and llama.cpp.
    private nonisolated static func probeOverSSH(server: ServerStatus, now: Date) -> ServerStatus {
        guard let host = server.url.host, !host.isEmpty else {
            return ServerStatus(name: server.name, url: server.url, isUp: false, telemetry: nil, checkedAt: now)
        }
        let target = server.url.user.map { "\($0)@\(host)" } ?? host
        let port = server.url.port ?? 8188
        let started = Date()
        let remoteCmd = """
        s=$(curl -sf -m 1.5 http://127.0.0.1:\(port)/system_stats 2>/dev/null); \
        if [ -n "$s" ]; then \
          printf '<<<COMFY_STATS>>>\\n%s\\n<<<COMFY_QUEUE>>>\\n' "$s"; \
          curl -sf -m 1.5 http://127.0.0.1:\(port)/queue 2>/dev/null; \
        else \
          h=$(curl -sf -m 1.5 http://127.0.0.1:\(port)/health 2>/dev/null); \
          if [ -n "$h" ]; then \
            printf '<<<HEALTH>>>\\n%s\\n<<<METRICS>>>\\n' "$h"; \
            curl -sf -m 1.5 http://127.0.0.1:\(port)/metrics 2>/dev/null; \
          else \
            m=$(curl -sf -m 1.5 http://127.0.0.1:\(port)/v1/models 2>/dev/null); \
            if [ -n "$m" ]; then printf '<<<MODELS>>>\\n%s\\n' "$m"; fi; \
          fi; \
        fi
        """
        let args = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=2",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=60",
            "-o", "ControlPath=/tmp/notchlite-ssh-%C",
            target,
            remoteCmd,
        ]
        guard let data = Kit.run("/usr/bin/ssh", args, timeout: 4),
              let text = String(data: data, encoding: .utf8) else {
            return ServerStatus(name: server.name, url: server.url, isUp: false, telemetry: nil, checkedAt: now)
        }
        let latencyMs = max(1, Int(Date().timeIntervalSince(started) * 1000))
        let parsed = ServerTelemetryParser.parseSSHProbeOutput(text)
        guard parsed.isUp else {
            return ServerStatus(name: server.name, url: server.url, isUp: false, telemetry: nil, checkedAt: now)
        }
        let elapsed = server.checkedAt.map { now.timeIntervalSince($0) }
        var merged = ServerTelemetryParser.merge(parsed.parts, previous: server.telemetry, elapsed: elapsed)
        merged.latencyMs = latencyMs
        return ServerStatus(name: server.name, url: server.url, isUp: true, telemetry: merged, checkedAt: now)
    }

    private static func stored() -> [ServerStatus] {
        (UserDefaults.standard.array(forKey: key) as? [[String: String]] ?? []).compactMap { entry in
            guard let name = entry["name"], let url = entry["url"].flatMap(URL.init(string:)) else { return nil }
            return ServerStatus(name: name, url: url, isUp: nil)
        }
    }

    /// One-time import of the servers.json used by earlier versions.
    private func importLegacyFile() {
        let file = Kit.home.appendingPathComponent(".config/notchlite/servers.json")
        guard UserDefaults.standard.object(forKey: Self.key) == nil,
              let data = try? Data(contentsOf: file),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return }
        UserDefaults.standard.set(entries, forKey: Self.key)
    }
}

// MARK: Microphone / camera in use

/// Mic and camera "in use" flags from CoreAudio and CoreMediaIO listeners
/// (public API, event driven).
@MainActor
final class PrivacyMonitor: ObservableObject {
    @Published private(set) var microphone = false
    @Published private(set) var camera = false

    private var running = false
    private var inputDevice = AudioObjectID(kAudioObjectUnknown)
    private var cameras: [CMIOObjectID] = []

    // Listeners use the function-pointer API, not the block one: Swift imports
    // the block typedefs as Swift closures and re-wraps them in a fresh block on
    // every call, so RemovePropertyListenerBlock never matched what Add had
    // registered. Listeners piled up, each event fired all of them, and every
    // one re-added more, until the main thread spun forever. Proc + clientData
    // compare by value, so removal is exact.
    private final class Token: @unchecked Sendable {
        weak var monitor: PrivacyMonitor?
    }
    private let token = Token()
    private var clientData: UnsafeMutableRawPointer { Unmanaged.passUnretained(token).toOpaque() }

    /// Default input or camera list changed → rebind; a device started/stopped → re-read flags.
    private static func deliver(_ data: UnsafeMutableRawPointer?, rebind: Bool) {
        guard let data else { return }
        let token = Unmanaged<Token>.fromOpaque(data).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let monitor = token.monitor else { return }
                if rebind { monitor.rebind() } else { monitor.refresh() }
            }
        }
    }

    private static let audioProc: AudioObjectPropertyListenerProc = { _, count, addresses, data in
        let rebind = (0..<Int(count)).contains { addresses[$0].mSelector == kAudioHardwarePropertyDefaultInputDevice }
        PrivacyMonitor.deliver(data, rebind: rebind)
        return noErr
    }

    private static let cameraProc: CMIOObjectPropertyListenerProc = { _, count, addresses, data in
        let rebind = addresses.map { list in
            (0..<Int(count)).contains { list[$0].mSelector == CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices) }
        } ?? true
        PrivacyMonitor.deliver(data, rebind: rebind)
        return noErr
    }

    private var defaultInput = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private var audioRunning = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private var cameraList = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    private var cameraRunning = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))

    func start() {
        guard !running else { return }
        running = true
        token.monitor = self
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &defaultInput, Self.audioProc, clientData)
        CMIOObjectAddPropertyListener(CMIOObjectID(kCMIOObjectSystemObject), &cameraList, Self.cameraProc, clientData)
        rebind()
    }

    func stop() {
        guard running else { return }
        running = false
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &defaultInput, Self.audioProc, clientData)
        CMIOObjectRemovePropertyListener(CMIOObjectID(kCMIOObjectSystemObject), &cameraList, Self.cameraProc, clientData)
        unbind()
        microphone = false
        camera = false
    }

    /// Re-attaches the per-device listeners and re-reads both flags.
    private func rebind() {
        guard running else { return }
        unbind()
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultInput, 0, nil, &size, &inputDevice)
        if inputDevice != kAudioObjectUnknown {
            AudioObjectAddPropertyListener(inputDevice, &audioRunning, Self.audioProc, clientData)
        }
        cameras = cameraDevices()
        for device in cameras {
            CMIOObjectAddPropertyListener(device, &cameraRunning, Self.cameraProc, clientData)
        }
        refresh()
    }

    /// Re-reads both flags without touching the listeners.
    private func refresh() {
        guard running else { return }
        let mic = inputDevice != kAudioObjectUnknown && isRunning(audio: inputDevice)
        let cam = cameras.contains { isRunning(camera: $0) }
        if mic != microphone { microphone = mic }
        if cam != camera { camera = cam }
    }

    private func unbind() {
        if inputDevice != kAudioObjectUnknown {
            AudioObjectRemovePropertyListener(inputDevice, &audioRunning, Self.audioProc, clientData)
        }
        for device in cameras {
            CMIOObjectRemovePropertyListener(device, &cameraRunning, Self.cameraProc, clientData)
        }
        inputDevice = AudioObjectID(kAudioObjectUnknown)
        cameras = []
    }

    private func isRunning(audio device: AudioObjectID) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &audioRunning, 0, nil, &size, &value) == noErr && value != 0
    }

    private func cameraDevices() -> [CMIOObjectID] {
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &cameraList, 0, nil, &size) == 0,
              size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &cameraList, 0, nil, size, &used, &devices) == 0
        else { return [] }
        return devices
    }

    private func isRunning(camera device: CMIOObjectID) -> Bool {
        var value: UInt32 = 0
        var used: UInt32 = 0
        return CMIOObjectGetPropertyData(device, &cameraRunning, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == 0
            && value != 0
    }
}

// MARK: Calendar

struct UpcomingEvent: Equatable {
    let title: String
    let start: Date
    let end: Date
    let color: NSColor
}

/// The next timed event in the next 12 hours, from every calendar on the Mac.
@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var next: UpcomingEvent?

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private var timer: Timer?

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // The event may start or end without the store changing.
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { if granted { self?.refresh() } } }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        timer?.invalidate()
        timer = nil
        next = nil
    }

    func refresh() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(12 * 3600), calendars: nil)
        let event = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .min { $0.startDate < $1.startDate }
        let upcoming = event.map {
            UpcomingEvent(title: $0.title ?? "Evento", start: $0.startDate, end: $0.endDate,
                          color: $0.calendar.color ?? .systemBlue)
        }
        if upcoming != next { next = upcoming }
    }
}

// MARK: Timer / reminder

/// One countdown with an optional reminder text; survives a restart.
@MainActor
final class TimerService: ObservableObject {
    @Published private(set) var endsAt: Date?
    @Published private(set) var label = ""
    var onFinish: ((String) -> Void)?

    private static let key = "timer"
    private var work: DispatchWorkItem?

    init() {
        if let saved = UserDefaults.standard.dictionary(forKey: Self.key),
           let end = saved["end"] as? Double, end > Date().timeIntervalSince1970 {
            schedule(Date(timeIntervalSince1970: end), label: saved["label"] as? String ?? "")
        }
    }

    func start(minutes: Double, label: String) {
        schedule(Date().addingTimeInterval(minutes * 60), label: label)
        UserDefaults.standard.set(["end": endsAt!.timeIntervalSince1970, "label": label], forKey: Self.key)
    }

    func cancel() {
        work?.cancel()
        endsAt = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    private func schedule(_ end: Date, label: String) {
        work?.cancel()
        endsAt = end
        self.label = label
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let label = self.label
                self.cancel()
                self.onFinish?(label)
            }
        }
        self.work = work
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + end.timeIntervalSinceNow, execute: work)
    }
}
