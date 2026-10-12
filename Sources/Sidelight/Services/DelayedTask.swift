/// Runs `action` once, after a delay: a debounced save, a refresh once things settle, a retry later. Scheduling again
/// replaces the run still waiting, so a burst of requests runs it once, a delay after the last.
final class DelayedTask {
    private var task: Task<Void, Never>?

    /// Whether a run is waiting.
    var isPending: Bool { task != nil }

    deinit {
        task?.cancel()
    }

    /// Runs `action` after `delay`, instead of any run still waiting. `tolerance` lets macOS group the wake-up with
    /// others.
    func schedule(after delay: Duration, tolerance: Duration? = nil, _ action: @escaping () -> Void) {
        task?.cancel()
        task = Task { [weak self] in
            do { try await Task.sleep(for: delay, tolerance: tolerance) } catch { return }
            // Replaced after waking but before running.
            guard !Task.isCancelled else { return }
            self?.task = nil
            action()
        }
    }

    /// Drops the run still waiting, if any.
    func cancel() {
        task?.cancel()
        task = nil
    }
}
