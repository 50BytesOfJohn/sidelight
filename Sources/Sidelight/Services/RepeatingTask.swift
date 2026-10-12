/// Runs `action` every `interval` until stopped: a service's periodic sweep, sample or refresh. The first run is one
/// interval after scheduling.
///
/// Asking for the interval it already runs at changes nothing, so a service can schedule from every read without
/// pushing its next run back.
final class RepeatingTask {
    private var task: Task<Void, Never>?
    private(set) var interval: Duration?

    var isRunning: Bool { task != nil }

    deinit {
        task?.cancel()
    }

    /// Runs `action` every `interval`, or stops when `interval` is `nil`. `tolerance` defaults to a quarter of the
    /// interval, which lets macOS group the wake-up with others.
    func schedule(every interval: Duration?, tolerance: Duration? = nil, _ action: @escaping () async -> Void) {
        guard interval != self.interval || (interval != nil && task == nil) else { return }
        stop()
        guard let interval else { return }
        self.interval = interval
        let tolerance = tolerance ?? interval / 4
        task = Task {
            while true {
                do { try await Task.sleep(for: interval, tolerance: tolerance) } catch { return }
                // Stopped after waking but before running.
                guard !Task.isCancelled else { return }
                await action()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        interval = nil
    }
}
