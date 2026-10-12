/// Runs `action` again and again, each run deciding how long to wait before the next: a fetch that follows a
/// provider's pace or backs off after failures, a check that's made less and less often. Ends when a run returns
/// `nil`, or on ``stop()``.
///
/// A run must check `Task.isCancelled` after each `await` and publish nothing once it's set, or a run started
/// before `stop()` could publish into the service after `start()`.
final class PacedTask {
    private var task: Task<Void, Never>?

    /// Whether a run is under way or waiting.
    var isRunning: Bool { task != nil }

    deinit {
        task?.cancel()
    }

    /// Runs `action` after `delay`, then after the wait each run returns, instead of whatever ran before.
    /// `tolerance` gives the leeway for a wait, letting macOS group the wake-up with others; a quarter by default.
    func start(
        after delay: Duration, tolerance: @escaping (Duration) -> Duration = { $0 / 4 },
        run action: @escaping () async -> Duration?
    ) {
        stop()
        task = Task { [weak self] in
            var wait: Duration? = delay
            while let delay = wait {
                if delay > .zero {
                    do { try await Task.sleep(for: delay, tolerance: tolerance(delay)) } catch { return }
                }
                // Stopped after waking but before running.
                guard !Task.isCancelled else { return }
                wait = await action()
                guard !Task.isCancelled else { return }
            }
            // Not cancelled since the last check, so this is still the current task.
            self?.task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
