import Foundation
import Observation
import SidelightCore

/// Samples CPU and memory usage every couple of seconds while running.
@Observable
final class SystemStatsService: DataService {
    static let interval: Duration = .seconds(2)

    /// Busy CPU percentage, 0–100.
    private(set) var cpuUsage: Double = 0
    private(set) var memory = MemoryUsage(usedBytes: 0, totalBytes: ProcessInfo.processInfo.physicalMemory)

    @ObservationIgnored private var sampler = SystemStatsSampler()
    @ObservationIgnored private let sampling = RepeatingTask()

    func start() {
        guard !sampling.isRunning else { return }
        // CPU usage is measured between two samples; one from before a stop would average over the whole pause.
        sampler = SystemStatsSampler()
        sample()
        sampling.schedule(every: Self.interval, tolerance: .milliseconds(200)) { [weak self] in self?.sample() }
    }

    func stop() {
        sampling.stop()
    }

    private func sample() {
        if let cpuUsage = sampler.cpuUsage(), cpuUsage != self.cpuUsage { self.cpuUsage = cpuUsage }
        if let memory = sampler.memoryUsage(), memory != self.memory { self.memory = memory }
    }
}
