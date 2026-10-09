import Foundation
import Observation
import SidelightCore

/// Samples CPU and memory usage every couple of seconds while running.
@Observable
final class SystemStatsService {
    static let interval: Duration = .seconds(2)

    /// Busy CPU percentage, 0–100.
    private(set) var cpuUsage: Double = 0
    private(set) var memory = MemoryUsage(usedBytes: 0, totalBytes: ProcessInfo.processInfo.physicalMemory)

    @ObservationIgnored private var sampler = SystemStatsSampler()
    @ObservationIgnored private var samplingTask: Task<Void, Never>?

    func start() {
        guard samplingTask == nil else { return }
        sample()
        samplingTask = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: Self.interval, tolerance: .milliseconds(200)) } catch { return }
                self?.sample()
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    private func sample() {
        if let cpuUsage = sampler.cpuUsage() { self.cpuUsage = cpuUsage }
        if let memory = sampler.memoryUsage() { self.memory = memory }
    }
}
