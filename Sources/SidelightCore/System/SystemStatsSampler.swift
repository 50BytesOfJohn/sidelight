import Darwin
import Foundation

/// Cumulative CPU ticks since boot, summed over all cores.
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// Busy percentage (0–100) between two readings; `nil` if no time passed. Handles counter wrap-around.
    public static func usage(from previous: CPUTicks, to current: CPUTicks) -> Double? {
        let user = Double(current.user &- previous.user)
        let system = Double(current.system &- previous.system)
        let idle = Double(current.idle &- previous.idle)
        let nice = Double(current.nice &- previous.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return (user + system + nice) / total * 100
    }
}

public struct MemoryUsage: Equatable, Sendable {
    public var usedBytes: UInt64
    public var totalBytes: UInt64

    public init(usedBytes: UInt64, totalBytes: UInt64) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
    }

    public var usedFraction: Double { totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) }
    public var usedGigabytes: Double { Double(usedBytes) / 1_073_741_824 }
    public var totalGigabytes: Double { Double(totalBytes) / 1_073_741_824 }
}

/// Reads CPU load and memory pressure from the Mach host statistics.
public struct SystemStatsSampler: Sendable {
    private var previousTicks: CPUTicks?

    public init() {}

    /// CPU usage since the previous call; `nil` on the first call.
    public mutating func cpuUsage() -> Double? {
        guard let ticks = Self.readCPUTicks() else { return nil }
        defer { previousTicks = ticks }
        return previousTicks.flatMap { CPUTicks.usage(from: $0, to: ticks) }
    }

    /// "Used" the way Activity Monitor's memory pressure sees it: active + wired + compressed pages.
    public func memoryUsage() -> MemoryUsage? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        let pages =
            UInt64(statistics.active_count) + UInt64(statistics.wire_count)
            + UInt64(statistics.compressor_page_count)
        return MemoryUsage(
            usedBytes: pages * UInt64(pageSize),
            totalBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    private static func readCPUTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )
    }
}
