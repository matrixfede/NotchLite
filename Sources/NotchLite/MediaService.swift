import AppKit
import ImageIO

struct Track: Equatable {
    var title: String
    var artist: String
    var duration: Double
    var elapsed: Double
    var timestamp: Date
    var rate: Double
    var isPlaying: Bool
    var bundleID: String?
    var clientKey: String? = nil
    var appName: String? = nil

    var identity: String { "\(title)|\(artist)" }

    func position(at now: Date) -> Double {
        guard isPlaying else { return elapsed }
        let speed = rate > 0 ? rate : 1
        let position = elapsed + now.timeIntervalSince(timestamp) * speed
        return duration > 0 ? min(max(position, 0), duration) : max(position, 0)
    }
}

/// Now Playing across macOS media clients (Apple Music, Spotify, YouTube Music
/// apps/PWAs, browsers…). Talks to MediaBridge.dylib hosted by /usr/bin/perl,
/// see Bridge/MediaBridge.m, and filters/ranks clients with MediaFilter.
@MainActor
final class MediaService: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var tint: NSColor = .white
    /// The track before the player went away, to resume it from the idle island.
    @Published private(set) var lastTrack: Track? = MediaService.storedLastTrack()
    @Published private(set) var lastArtwork: NSImage?

    /// When true, ignores browsers, social media, and video players so only
    /// dedicated music apps appear in the notch.
    var musicOnly: Bool = true {
        didSet {
            guard oldValue != musicOnly else { return }
            reselect()
        }
    }

    var visibleLastTrack: Track? {
        guard let lastTrack else { return nil }
        if musicOnly, !MediaFilter.isMusicSource(bundleID: lastTrack.bundleID, appName: lastTrack.appName ?? "") {
            return nil
        }
        return lastTrack
    }

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var running = false
    private var restartDelay: TimeInterval = 1
    private var restartWork: DispatchWorkItem?
    private var latestCandidates: [MediaCandidate] = []
    private var activeArtworkKey: String?
    private var artworkCache: [String: (image: NSImage, tint: NSColor)] = [:]
    private var artworkCacheOrder: [String] = []
    private static let maxCachedArtworks = 16

    func start() {
        guard !running else { return }
        running = true
        launch()
    }

    func stop() {
        guard running else { return }
        running = false
        restartWork?.cancel()
        process?.terminate()
        process = nil
        input = nil
        buffer.removeAll()
        latestCandidates.removeAll()
        track = nil
        artwork = nil
        activeArtworkKey = nil
    }

    #if DEBUG
    func debugSet(track: Track?, artwork: NSImage?, tint: NSColor) {
        if track == nil, let current = self.track { remember(current) }
        self.track = track
        self.artwork = artwork
        self.tint = tint
    }
    #endif

    // MARK: Commands

    func togglePlayPause() {
        guard var current = track else { return }
        sendCommand(current.isPlaying ? "pause" : "play", clientKey: current.clientKey)
        // Optimistic update so the UI reacts instantly.
        current.elapsed = current.position(at: Date())
        current.timestamp = Date()
        current.isPlaying.toggle()
        track = current
    }

    func next() { sendCommand("next", clientKey: track?.clientKey) }
    func previous() { sendCommand("previous", clientKey: track?.clientKey) }

    func seek(toFraction fraction: Double) {
        guard var current = track, current.duration > 0 else { return }
        let seconds = current.duration * min(max(fraction, 0), 1)
        let base = String(format: "seek %.2f", seconds)
        if let key = current.clientKey, !key.isEmpty {
            send("\(base) \(key)")
        } else {
            send(base)
        }
        current.elapsed = seconds
        current.timestamp = Date()
        track = current
    }

    /// Plays the last track again: targets its client/bundle when the app is
    /// still open, otherwise reopens the app.
    func resumeLast() {
        guard let last = visibleLastTrack, let bundleID = last.bundleID else { return }
        if let matching = latestCandidates.first(where: { $0.bundleID?.lowercased() == bundleID.lowercased() }) {
            sendCommand("play", clientKey: matching.clientKey)
            return
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            send("playBundle \(bundleID)")
        }
    }

    private func remember(_ track: Track) {
        if musicOnly, !MediaFilter.isMusicSource(bundleID: track.bundleID, appName: track.appName ?? "") {
            return
        }
        lastTrack = track
        lastArtwork = artwork
        UserDefaults.standard.set([
            "title": track.title,
            "artist": track.artist,
            "bundleID": track.bundleID ?? "",
            "appName": track.appName ?? "",
        ], forKey: "lastTrack")
    }

    private static func storedLastTrack() -> Track? {
        guard let entry = UserDefaults.standard.dictionary(forKey: "lastTrack") as? [String: String],
              let title = entry["title"], let bundleID = entry["bundleID"], !bundleID.isEmpty else { return nil }
        return Track(
            title: title,
            artist: entry["artist"] ?? "",
            duration: 0,
            elapsed: 0,
            timestamp: Date(),
            rate: 1,
            isPlaying: false,
            bundleID: bundleID,
            appName: entry["appName"]
        )
    }

    func openPlayer() {
        guard let bundleID = track?.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func sendCommand(_ command: String, clientKey: String?) {
        if let key = clientKey, !key.isEmpty {
            send("\(command) \(key)")
        } else {
            send(command)
        }
    }

    private func send(_ command: String) {
        guard let data = (command + "\n").data(using: .utf8) else { return }
        try? input?.write(contentsOf: data)
    }

    // MARK: Bridge process

    private func launch() {
        guard running,
              let resources = Bundle.main.resourceURL else { return }
        let script = resources.appendingPathComponent("media.pl")
        let library = resources.appendingPathComponent("MediaBridge.dylib")
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: library.path) else {
            NSLog("NotchLite: media bridge missing from bundle")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, library.path]
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.consume(data) }
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.bridgeDidExit(finished, status: status) }
            }
        }

        do {
            try process.run()
            self.process = process
            self.input = input.fileHandleForWriting
        } catch {
            scheduleRestart()
        }
    }

    private func bridgeDidExit(_ finished: Process, status: Int32) {
        guard finished === process else { return }
        process = nil
        input = nil
        buffer.removeAll()
        guard running else { return }
        // Status 2: MediaRemote unavailable on this macOS, give up. Anything
        // else (e.g. a crash on odd metadata) retries with backoff, up to 30 s.
        if status == 2 {
            NSLog("NotchLite: media bridge unavailable (status \(status))")
            return
        }
        scheduleRestart()
    }

    private func scheduleRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.launch() }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay, execute: work)
        restartDelay = min(restartDelay * 2, 30)
    }

    private func consume(_ data: Data) {
        guard running, !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                restartDelay = 1
                handle(object)
            }
        }
        if buffer.count > 16_000_000 { buffer.removeAll() } // corrupted stream guard
    }

    private func handle(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }

        switch type {
        case "clients":
            let rawItems = message["items"] as? [[String: Any]] ?? []
            var parsed: [MediaCandidate] = []
            parsed.reserveCapacity(rawItems.count)
            for item in rawItems {
                guard let candidate = parseCandidate(item) else { continue }
                parsed.append(candidate)
                if let artKey = candidate.artworkKey, let base64 = item["artwork"] as? String {
                    decodeAndCacheArtwork(base64, forKey: artKey)
                }
            }
            latestCandidates = parsed
            reselect()

        case "track":
            // Legacy single-track fallback format.
            if let candidate = parseCandidate(message) {
                if let artKey = candidate.artworkKey, let base64 = message["artwork"] as? String {
                    decodeAndCacheArtwork(base64, forKey: artKey)
                }
                latestCandidates = [candidate]
            } else {
                latestCandidates = []
            }
            reselect()

        default:
            latestCandidates = []
            reselect()
        }
    }

    private func parseCandidate(_ item: [String: Any]) -> MediaCandidate? {
        guard let title = item["title"] as? String, !title.isEmpty else { return nil }
        let artist = item["artist"] as? String ?? ""
        let pid = Int32(item["pid"] as? Int ?? 0)
        let bundleID = item["bundleID"] as? String
        let rawBundleID = item["rawBundleID"] as? String
        let clientKey = (item["clientKey"] as? String) ?? "\(pid)|\(rawBundleID ?? bundleID ?? "")"
        let timestamp = (item["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        let lastPlayingDate = (item["lastPlayingDate"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let artworkKey = (item["artworkKey"] as? String) ?? (item["artwork"] != nil ? "\(title)|\(artist)" : nil)

        return MediaCandidate(
            clientKey: clientKey,
            pid: pid,
            bundleID: bundleID,
            rawBundleID: rawBundleID,
            appName: item["appName"] as? String ?? "",
            title: title,
            artist: artist,
            album: item["album"] as? String ?? "",
            duration: item["duration"] as? Double ?? 0,
            elapsed: item["elapsed"] as? Double ?? 0,
            timestamp: timestamp,
            rate: item["rate"] as? Double ?? 1,
            isPlaying: item["playing"] as? Bool ?? false,
            lastPlayingDate: lastPlayingDate,
            mediaType: item["mediaType"] as? String,
            isMusicApp: item["isMusicApp"] as? Bool ?? false,
            isGlobal: item["isGlobal"] as? Bool ?? false,
            artworkKey: artworkKey
        )
    }

    private func reselect() {
        guard let selected = MediaFilter.select(from: latestCandidates, musicOnly: musicOnly) else {
            if let current = track { remember(current) }
            track = nil
            artwork = nil
            tint = .white
            activeArtworkKey = nil
            return
        }

        let next = Track(
            title: selected.title,
            artist: selected.artist,
            duration: selected.duration,
            elapsed: selected.elapsed,
            timestamp: selected.timestamp,
            rate: selected.rate,
            isPlaying: selected.isPlaying,
            bundleID: selected.bundleID,
            clientKey: selected.clientKey,
            appName: selected.appName
        )

        let previousArtworkKey = activeArtworkKey
        if next != track { track = next }

        activeArtworkKey = selected.artworkKey
        if let artKey = selected.artworkKey {
            if let cached = artworkCache[artKey] {
                artwork = cached.image
                tint = cached.tint
            } else if previousArtworkKey != artKey {
                artwork = nil
                tint = .white
            }
        } else {
            artwork = nil
            tint = .white
        }
    }

    private func decodeAndCacheArtwork(_ base64: String, forKey artKey: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let decoded = Self.decodeArtwork(base64)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, let decoded else { return }
                    self.storeCachedArtwork(decoded, forKey: artKey)
                    if self.activeArtworkKey == artKey {
                        self.artwork = decoded.image
                        self.tint = decoded.tint
                    }
                }
            }
        }
    }

    private func storeCachedArtwork(_ decoded: (image: NSImage, tint: NSColor), forKey key: String) {
        artworkCache[key] = decoded
        artworkCacheOrder.removeAll { $0 == key }
        artworkCacheOrder.append(key)
        while artworkCacheOrder.count > Self.maxCachedArtworks {
            let oldest = artworkCacheOrder.removeFirst()
            artworkCache.removeValue(forKey: oldest)
        }
    }

    private nonisolated static func decodeArtwork(_ base64: String) -> (image: NSImage, tint: NSColor)? {
        guard let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 192,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return (image, averageColor(of: cgImage))
    }

    private nonisolated static func averageColor(of image: CGImage) -> NSColor {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .white }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let color = NSColor(
            deviceRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255, alpha: 1
        )
        // Keep the tint readable on a black island.
        return NSColor(
            deviceHue: color.hueComponent,
            saturation: min(color.saturationComponent, 0.75),
            brightness: max(color.brightnessComponent, 0.75),
            alpha: 1
        )
    }
}
