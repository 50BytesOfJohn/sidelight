import Foundation
import Synchronization

/// Waits until `condition` holds, checking every few milliseconds; `false` if it doesn't within `timeout`.
@discardableResult
func eventually(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// Answers to calls the code under test makes, handed out by the test one at a time: each call waits until the
/// test answers it, so the test decides what the code sees and when.
final class Answers<Value: Sendable>: Sendable {
    private let waiting = Mutex<[CheckedContinuation<Value, Never>]>([])
    private let calls = Mutex(0)

    /// Called by the code under test.
    func next() async -> Value {
        calls.withLock { $0 += 1 }
        return await withCheckedContinuation { continuation in
            waiting.withLock { $0.append(continuation) }
        }
    }

    /// How many calls have been made so far.
    var callCount: Int { calls.withLock { $0 } }

    var pendingCount: Int { waiting.withLock { $0.count } }

    /// Answers the oldest waiting call, once there is one.
    func answer(_ value: Value) async {
        await eventually { pendingCount > 0 }
        let continuation = waiting.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        continuation?.resume(returning: value)
    }
}
