import Foundation
import Darwin

// MARK: - System stats

final class StatsModel: ObservableObject {
    @Published var cpu: Double = 0
    @Published var memUsedGB: Double = 0
    @Published var memTotalGB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    @Published var selfRSSMB: Double = 0
    private var prev: host_cpu_load_info?
    private var timer: Timer?
    init() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.2
    }
    func tick() {
        var info = host_cpu_load_info(); var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) } }
        if r == KERN_SUCCESS {
            if let p = prev {
                let u = Double(info.cpu_ticks.0 &- p.cpu_ticks.0), s = Double(info.cpu_ticks.1 &- p.cpu_ticks.1)
                let i = Double(info.cpu_ticks.2 &- p.cpu_ticks.2), n = Double(info.cpu_ticks.3 &- p.cpu_ticks.3)
                let tot = u + s + i + n; if tot > 0 { cpu = (u + s + n) / tot * 100 }
            }
            prev = info
        }
        var vm = vm_statistics64(); var c2 = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r2 = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c2)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c2) } }
        if r2 == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            memUsedGB = (Double(vm.active_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page / 1_073_741_824
        }
        var ti = mach_task_basic_info(); var c3 = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let r3 = withUnsafeMutablePointer(to: &ti) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c3)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &c3) } }
        if r3 == KERN_SUCCESS { selfRSSMB = Double(ti.resident_size) / 1_048_576 }
    }
}

