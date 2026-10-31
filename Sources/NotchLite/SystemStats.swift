import Foundation
import IOKit

/// "Sistema" panel data (Omarchy's power panel): CPU, memory, battery details.
/// Runs only while the panel is on screen.
@MainActor
final class SystemStats: ObservableObject {
    @Published private(set) var cpu: Double?
    @Published private(set) var memoryUsed: UInt64 = 0
    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var watts: Double?
    @Published private(set) var minutesLeft: Int?
    @Published private(set) var cycles: Int?
    @Published private(set) var health: Int?
    @Published private(set) var thermal = ProcessInfo.ThermalState.nominal

    private var timer: Timer?
    private var lastTicks: (busy: UInt64, total: UInt64)?

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        read()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastTicks = nil
        cpu = nil
    }

    private func read() {
        readCPU()
        readMemory()
        readBattery()
        thermal = ProcessInfo.processInfo.thermalState
    }

    /// Busy share of all CPU ticks since the previous sample.
    private func readCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let t = info.cpu_ticks
        let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3) // user + system + nice
        let total = busy + UInt64(t.2)
        if let last = lastTicks, total > last.total {
            cpu = Double(busy - last.busy) / Double(total - last.total)
        }
        lastTicks = (busy, total)
    }

    /// Like Activity Monitor's "memory used": app + wired + compressed.
    private func readMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let pages = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
            + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        memoryUsed = pages * UInt64(vm_kernel_page_size)
    }

    private func readBattery() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        func int(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber).map { Int($0.int64Value) } // amperage is signed
        }
        if let volts = int("Voltage"), let amps = int("InstantAmperage") ?? int("Amperage") {
            watts = abs(Double(volts) * Double(amps)) / 1_000_000
        }
        let left = int("TimeRemaining") ?? 0
        minutesLeft = left > 0 && left < 6000 ? left : nil // 65535 while still estimating
        cycles = int("CycleCount")
        health = int("MaxCapacity")
    }
}
