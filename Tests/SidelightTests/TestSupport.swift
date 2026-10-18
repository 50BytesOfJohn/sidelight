import Foundation
import Synchronization

/// Waits until `condition` holds, checking every few milliseconds; `false` if it doesn't within `timeout`.
///
/// This is how a test waits for something to happen. Never wait a fixed time for that instead: the suite is
/// main-actor isolated, so under load the test's own wake-up and the work it waits for queue up together and
/// need not be serviced in deadline order, and the test fails on a busy machine while passing on an idle one.
@discardableResult
func eventually(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// Gives work already in flight a chance to run, for asserting that something *doesn't* happen.
///
/// A longer wait only makes such an assertion stricter, so load can't turn it into a false failure. Waiting for
/// something to happen is the opposite case and belongs in `eventually`.
func settle(_ duration: Duration = .milliseconds(50)) async {
    try? await Task.sleep(for: duration)
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
