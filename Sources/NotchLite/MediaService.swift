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

    var identity: String { "\(title)|\(artist)" }

    func position(at now: Date) -> Double {
        guard isPlaying else { return elapsed }
        let speed = rate > 0 ? rate : 1
        let position = elapsed + now.timeIntervalSince(timestamp) * speed
        return duration > 0 ? min(max(position, 0), duration) : max(position, 0)
    }
}

/// Now Playing for every source that reports to macOS (Apple Music, Spotify,
/// browsers, YouTube Music apps…). Talks to MediaBridge.dylib hosted by
/// /usr/bin/perl, see Bridge/MediaBridge.m.
@MainActor
final class MediaService: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var tint: NSColor = .white
    /// The track before the player went away, to resume it from the idle island.
    @Published private(set) var lastTrack: Track? = MediaService.storedLastTrack()
    @Published private(set) var lastArtwork: NSImage?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var running = false
    private var restartDelay: TimeInterval = 1
    private var restartWork: DispatchWorkItem?
    private var artworkIdentity: String?

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
        track = nil
        artwork = nil
        artworkIdentity = nil
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
        send(current.isPlaying ? "pause" : "play")
        // Optimistic update so the UI reacts instantly.
        current.elapsed = current.position(at: Date())
        current.timestamp = Date()
        current.isPlaying.toggle()
        track = current
    }

    func next() { send("next") }
    func previous() { send("previous") }

    func seek(toFraction fraction: Double) {
        guard var current = track, current.duration > 0 else { return }
        let seconds = current.duration * min(max(fraction, 0), 1)
        send(String(format: "seek %.2f", seconds))
        current.elapsed = seconds
        current.timestamp = Date()
        track = current
    }

    /// Plays the last track again: the play command when its app is still
    /// open, otherwise just reopens the app.
    func resumeLast() {
        guard let bundleID = lastTrack?.bundleID else { return }
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            send("play")
        }
    }

    private func remember(_ track: Track) {
        lastTrack = track
        lastArtwork = artwork
        UserDefaults.standard.set(["title": track.title, "artist": track.artist, "bundleID": track.bundleID ?? ""],
                                  forKey: "lastTrack")
    }

    private static func storedLastTrack() -> Track? {
        guard let entry = UserDefaults.standard.dictionary(forKey: "lastTrack") as? [String: String],
              let title = entry["title"], let bundleID = entry["bundleID"], !bundleID.isEmpty else { return nil }
        return Track(title: title, artist: entry["artist"] ?? "", duration: 0, elapsed: 0, timestamp: Date(),
                     rate: 1, isPlaying: false, bundleID: bundleID)
    }

    func openPlayer() {
        guard let bundleID = track?.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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
        guard message["type"] as? String == "track",
              let title = message["title"] as? String else {
            if let track { remember(track) }
            track = nil
            artwork = nil
            artworkIdentity = nil
            return
        }

        let timestamp = (message["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        let next = Track(
            title: title,
            artist: message["artist"] as? String ?? "",
            duration: message["duration"] as? Double ?? 0,
            elapsed: message["elapsed"] as? Double ?? 0,
            timestamp: timestamp,
            rate: message["rate"] as? Double ?? 1,
            isPlaying: message["playing"] as? Bool ?? false,
            bundleID: message["bundleID"] as? String
        )

        if next.identity != artworkIdentity, message["artwork"] == nil {
            artwork = nil
            tint = .white
        }
        if next != track { track = next }

        if let base64 = message["artwork"] as? String {
            let identity = next.identity
            artworkIdentity = identity
            DispatchQueue.global(qos: .userInitiated).async {
                let decoded = Self.decodeArtwork(base64)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { [weak self] in
                        guard let self, self.artworkIdentity == identity else { return }
                        self.artwork = decoded?.image
                        self.tint = decoded?.tint ?? .white
                    }
                }
            }
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
