import AppKit
import CoreAudio
import CoreMediaIO
import EventKit

/// The small ambient services, owned together.
@MainActor
final class Ambient {
    let servers = ServerMonitor()
    let privacy = PrivacyMonitor()
    let calendar = CalendarService()
    let shelf = Shelf()
    let network = NetworkService()
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
}

/// Pings the local model servers once a minute; any HTTP answer counts as up.
/// The list is edited from the menu bar and kept in the app's preferences.
@MainActor
final class ServerMonitor: ObservableObject {
    @Published private(set) var servers: [ServerStatus] = []

    private static let key = "servers"
    private var timer: Timer?

    init() {
        importLegacyFile()
        servers = Self.stored()
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
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
        servers = entries
        check()
    }

    private func check() {
        let list = servers
        guard !list.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let results = list.map { ServerStatus(name: $0.name, url: $0.url, isUp: Kit.request($0.url, timeout: 3).status > 0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Ignore an answer for a list that was edited meanwhile.
                    if results.map(\.name) == self.servers.map(\.name), results != self.servers { self.servers = results }
                }
            }
        }
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
    private lazy var audioListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.rebind() }
    }
    private lazy var cameraListener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.rebind() }
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
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInput, .main, audioListener)
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &cameraList, .main, cameraListener)
        rebind()
    }

    func stop() {
        guard running else { return }
        running = false
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInput, .main, audioListener)
        CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &cameraList, .main, cameraListener)
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
            AudioObjectAddPropertyListenerBlock(inputDevice, &audioRunning, .main, audioListener)
        }
        cameras = cameraDevices()
        for device in cameras {
            CMIOObjectAddPropertyListenerBlock(device, &cameraRunning, .main, cameraListener)
        }
        let mic = inputDevice != kAudioObjectUnknown && isRunning(audio: inputDevice)
        let cam = cameras.contains { isRunning(camera: $0) }
        if mic != microphone { microphone = mic }
        if cam != camera { camera = cam }
    }

    private func unbind() {
        if inputDevice != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(inputDevice, &audioRunning, .main, audioListener)
        }
        for device in cameras {
            CMIOObjectRemovePropertyListenerBlock(device, &cameraRunning, .main, cameraListener)
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
