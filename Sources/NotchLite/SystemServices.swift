import AppKit
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: Battery

enum BatteryEvent {
    case plugged(Int)
    case unplugged(Int)
    case low(Int)
}

/// Event driven (IOPS notifications), no polling.
@MainActor
final class BatteryService: ObservableObject {
    @Published private(set) var level = 100
    @Published private(set) var isCharging = false
    @Published private(set) var isPluggedIn = false
    @Published private(set) var hasBattery = false

    var onEvent: ((BatteryEvent) -> Void)?
    private var source: CFRunLoopSource?
    private var warnedLow = false
    private let lowThreshold = 20

    func start() {
        guard source == nil else { return }
        update(notify: false)
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let service = Unmanaged<BatteryService>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { service.update(notify: true) }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    private func update(notify: Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return }
        let internalBattery = sources.lazy
            .compactMap { IOPSGetPowerSourceDescription(snapshot, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
        guard let info = internalBattery else {
            hasBattery = false
            return
        }

        let current = info[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maximum = max(info[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
        let newLevel = Int((Double(current) / Double(maximum) * 100).rounded())
        let plugged = info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let wasPlugged = isPluggedIn

        hasBattery = true
        if level != newLevel { level = newLevel }
        isCharging = info[kIOPSIsChargingKey] as? Bool ?? false
        if isPluggedIn != plugged { isPluggedIn = plugged }

        if plugged || newLevel > lowThreshold { warnedLow = false }
        guard notify else { return }
        if plugged != wasPlugged {
            onEvent?(plugged ? .plugged(newLevel) : .unplugged(newLevel))
        } else if !plugged, newLevel <= lowThreshold, !warnedLow {
            warnedLow = true
            onEvent?(.low(newLevel))
        }
    }
}

// MARK: Volume

/// Listens to CoreAudio for output volume / mute changes on the default device.
@MainActor
final class VolumeService {
    var onChange: ((Float, Bool) -> Void)?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var running = false
    private var lastValue: (Float, Bool)?
    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.bindDefaultDevice() }
    }
    private lazy var valueListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.valueChanged() }
    }

    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    func start() {
        guard !running else { return }
        running = true
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, .main, deviceListener)
        bindDefaultDevice()
    }

    func stop() {
        guard running else { return }
        running = false
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, .main, deviceListener)
        unbind()
    }

    private func bindDefaultDevice() {
        unbind()
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return }
        device = id
        if AudioObjectHasProperty(id, &volumeAddress) {
            AudioObjectAddPropertyListenerBlock(id, &volumeAddress, .main, valueListener)
        }
        if AudioObjectHasProperty(id, &muteAddress) {
            AudioObjectAddPropertyListenerBlock(id, &muteAddress, .main, valueListener)
        }
        lastValue = read()
    }

    private func unbind() {
        guard device != kAudioObjectUnknown else { return }
        AudioObjectRemovePropertyListenerBlock(device, &volumeAddress, .main, valueListener)
        AudioObjectRemovePropertyListenerBlock(device, &muteAddress, .main, valueListener)
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func read() -> (Float, Bool)? {
        guard device != kAudioObjectUnknown else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume) == noErr else { return nil }
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &muteAddress) {
            AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted)
        }
        return (volume, muted != 0)
    }

    private func valueChanged() {
        guard running, let value = read() else { return }
        if let last = lastValue, abs(last.0 - value.0) < 0.001, last.1 == value.1 { return }
        lastValue = value
        onChange?(value.0, value.1)
    }
}
