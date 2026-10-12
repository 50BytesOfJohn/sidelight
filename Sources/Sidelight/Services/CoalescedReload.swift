/// Runs a service's read one at a time: requests that arrive while it reads are gathered into one more read after
/// it, so a burst of file events costs at most two reads.
///
/// ``cancel()`` cancels the read in flight. A read must check `Task.isCancelled` after each `await` and publish
/// nothing once it's set, or a read started before `stop()` could publish into the service after `start()`.
final class CoalescedReload {
    private var task: Task<Void, Never>?
    private var isRequested = false
    /// Tells a task that a `cancel()` replaced it, so it doesn't clear its replacement's handle as it ends.
    private var generation = 0

    /// Whether a read is running or waiting to start.
    var isActive: Bool { task != nil }

    deinit {
        task?.cancel()
    }

    /// Reads once more, after `delay` if no read is under way yet. `read` is the same work on every request.
    func request(after delay: Duration = .zero, _ read: @escaping () async -> Void) {
        isRequested = true
        guard task == nil else { return }
        generation += 1
        let generation = generation
        task = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            while let self, isRequested, !Task.isCancelled {
                isRequested = false
                await read()
            }
            if let self, self.generation == generation { task = nil }
        }
    }

    /// Drops the read under way and any request waiting for it.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        isRequested = false
    }
}
