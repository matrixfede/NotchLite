import CoreWLAN
import Foundation
import SystemConfiguration

struct Ping: Equatable {
    var ms: Double?
    var loss: Double?
}

struct TailnetPeer: Identifiable, Equatable {
    var id: String { host }
    let name: String
    let host: String // MagicDNS short name, safe for `ssh`
    let ip: String
    let online: Bool
}

struct SpeedResult: Equatable {
    let down: Double // bit/s
    let up: Double
    let latency: Double // ms
}

/// Network panel data, like Omarchy's: link, addresses, throughput and ping.
/// Runs only while the "Rete" tab is on screen.
@MainActor
final class NetworkService: ObservableObject {
    @Published private(set) var interface: String?
    /// The primary route goes through a VPN tunnel (utun/ppp/ipsec).
    var isTunnel: Bool { ["utun", "ppp", "ipsec"].contains { interface?.hasPrefix($0) == true } }
    @Published private(set) var wifi: (rssi: Int, rate: Double, band: String)?
    @Published private(set) var ip: String?
    @Published private(set) var gateway: String?
    @Published private(set) var received: UInt64 = 0
    @Published private(set) var sent: UInt64 = 0
    @Published private(set) var downRate: Double?
    @Published private(set) var upRate: Double?
    @Published private(set) var routerPing = Ping()
    @Published private(set) var internetPing = Ping()
    /// nil when Tailscale isn't installed; empty IP while it is off.
    @Published private(set) var tailnet: (ip: String, peers: [TailnetPeer])?
    @Published private(set) var speed: SpeedResult?
    @Published private(set) var isTesting = false

    static let internetHost = "1.1.1.1"
    private let store = SCDynamicStoreCreate(nil, "NotchLite" as CFString, nil, nil)
    private var timer: Timer?
    private var ticks = 0
    private var pinging = false
    private var sampledAt = Date()
    /// The last speed test failed (offline, or networkQuality unavailable).
    @Published private(set) var speedFailed = false

    func start() {
        guard timer == nil else { return }
        ticks = 0
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        received = 0 // the next open must not divide by the closed time
        sent = 0
        downRate = nil
        upRate = nil
    }

    private func tick() {
        readLink()
        readCounters()
        if ticks % 5 == 0 { ping() }
        if ticks % 10 == 0 { readTailnet() }
        ticks += 1
    }

    private func readLink() {
        let global = value("State:/Network/Global/IPv4")
        let name = global?["PrimaryInterface"] as? String
        if name != interface { // counters of another interface: start over
            interface = name
            received = 0
            sent = 0
            downRate = nil
            upRate = nil
        }
        let router = global?["Router"] as? String
        if router != gateway { gateway = router }
        let address = name.flatMap { value("State:/Network/Interface/\($0)/IPv4")?["Addresses"] as? [String] }?.first
        if address != ip { ip = address }

        let radio = CWWiFiClient.shared().interface()
        // Under a VPN the Wi-Fi radio still carries the traffic.
        if let radio, radio.interfaceName == name || isTunnel, let channel = radio.wlanChannel() {
            let band = switch channel.channelBand {
            case .band2GHz: "2,4 GHz"
            case .band5GHz: "5 GHz"
            case .band6GHz: "6 GHz"
            default: ""
            }
            wifi = (radio.rssiValue(), radio.transmitRate(), band)
        } else if wifi != nil {
            wifi = nil
        }
    }

    private func value(_ key: String) -> [String: Any]? {
        store.flatMap { SCDynamicStoreCopyValue($0, key as CFString) as? [String: Any] }
    }

    /// 64-bit byte counters of the primary interface (NET_RT_IFLIST2).
    private func readCounters() {
        guard let name = interface else { return }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return }
        let index = if_nametoindex(name)
        var rx: UInt64?, tx: UInt64?
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.load(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(header.ifm_type) == RTM_IFINFO2, UInt32(header.ifm_index) == index {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    rx = message.ifm_data.ifi_ibytes
                    tx = message.ifm_data.ifi_obytes
                    break
                }
                offset += Int(header.ifm_msglen)
                if header.ifm_msglen == 0 { break }
            }
        }
        guard let rx, let tx else { return }
        // A rate needs a previous sample on the same interface; timer ticks
        // drift, so divide by the real interval.
        let now = Date()
        let seconds = now.timeIntervalSince(sampledAt)
        if received > 0, rx >= received, tx >= sent, seconds > 0.2 {
            downRate = Double(rx - received) / seconds
            upRate = Double(tx - sent) / seconds
        }
        received = rx
        sent = tx
        sampledAt = now
    }

    private func ping() {
        guard !pinging else { return }
        pinging = true
        let router = isTunnel ? nil : gateway // a tunnel's "router" is itself
        DispatchQueue.global(qos: .utility).async {
            let group = DispatchGroup()
            var routerResult = Ping(), internetResult = Ping()
            if let router {
                DispatchQueue.global(qos: .utility).async(group: group) { routerResult = Self.ping(router) }
            }
            internetResult = Self.ping(Self.internetHost)
            group.wait()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pinging = false
                    guard self.timer != nil else { return }
                    self.routerPing = routerResult
                    self.internetPing = internetResult
                }
            }
        }
    }

    private static let tailscale = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

    private func readTailnet() {
        guard FileManager.default.isExecutableFile(atPath: Self.tailscale) else { return }
        DispatchQueue.global(qos: .utility).async {
            let data = Self.run(Self.tailscale, ["status", "--json"])
            var result: (ip: String, peers: [TailnetPeer])?
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if json != nil { result = ("", []) }
            if let json, json["BackendState"] as? String == "Running" {
                let me = (json["Self"] as? [String: Any])?["TailscaleIPs"] as? [String]
                let peers = (json["Peer"] as? [String: [String: Any]] ?? [:]).values.compactMap { peer -> TailnetPeer? in
                    guard let ip = (peer["TailscaleIPs"] as? [String])?.first,
                          let host = (peer["DNSName"] as? String)?.split(separator: ".").first.map(String.init),
                          host.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else { return nil }
                    return TailnetPeer(name: peer["HostName"] as? String ?? host, host: host, ip: ip,
                                       online: peer["Online"] as? Bool ?? false)
                }
                .sorted { ($0.online ? 0 : 1, $0.name.lowercased()) < ($1.online ? 0 : 1, $1.name.lowercased()) }
                result = (me?.first ?? "", peers)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.tailnet?.ip != result?.ip || self.tailnet?.peers != result?.peers { self.tailnet = result }
                }
            }
        }
    }

    /// macOS's own `networkQuality` (about 20 s); runs on demand only.
    func speedTest() {
        guard !isTesting else { return }
        isTesting = true
        speedFailed = false
        DispatchQueue.global(qos: .utility).async {
            let data = Self.run("/usr/bin/networkQuality", ["-c"])
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let result = json.flatMap { json -> SpeedResult? in
                guard let down = json["dl_throughput"] as? Double, let up = json["ul_throughput"] as? Double else { return nil }
                return SpeedResult(down: down, up: up, latency: json["base_rtt"] as? Double ?? 0)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isTesting = false
                    self.speed = result
                    self.speedFailed = result == nil
                }
            }
        }
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return Data() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    /// Three quick pings with /sbin/ping (no root needed): average and loss.
    nonisolated private static func ping(_ host: String) -> Ping {
        let output = String(decoding: run("/sbin/ping", ["-n", "-q", "-c", "3", "-i", "0.2", "-t", "2", host]), as: UTF8.self)
        var result = Ping()
        for line in output.split(separator: "\n") {
            if line.contains("packet loss"), let field = line.split(separator: ",").first(where: { $0.contains("%") }) {
                result.loss = Double(field.trimmingCharacters(in: .whitespaces).split(separator: "%").first ?? "")
            } else if line.hasPrefix("round-trip"), let stats = line.split(separator: "=").last {
                let parts = stats.split(separator: "/")
                if parts.count > 1 { result.ms = Double(parts[1].trimmingCharacters(in: .whitespaces)) }
            }
        }
        return result
    }
}
