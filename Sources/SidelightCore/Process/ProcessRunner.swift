import Foundation
import Synchronization

/// Runs short-lived command-line tools without blocking a thread while they run.
public enum ProcessRunner {
    /// How long a cancelled tool has to exit after being asked to before it's killed.
    static let killDelay: DispatchTimeInterval = .seconds(2)

    /// Runs `executable` to completion and returns its exit status (or `-1` if it couldn't be started).
    public static func run(_ executable: URL, arguments: [String]) async -> Int32 {
        await result(of: executable, arguments: arguments)?.status ?? -1
    }

    /// Runs `executable` to completion and returns what it wrote to standard output, or `nil` if it couldn't be
    /// started, exited with an error or was cancelled. For tools with short output.
    public static func output(of executable: URL, arguments: [String]) async -> Data? {
        guard let result = await result(of: executable, arguments: arguments), result.status == 0 else { return nil }
        return result.output
    }

    /// What a tool printed and how it exited.
    public struct Result: Sendable {
        public var status: Int32
        public var output: Data
        public var error: Data

        public init(status: Int32, output: Data, error: Data) {
            self.status = status
            self.output = output
            self.error = error
        }
    }

    /// Runs `executable` to completion and returns everything it printed, for tools that explain a failure on
    /// standard error. Cancelling the task terminates the tool, so one waiting on something (such as a question to
    /// the person) doesn't outlive the reason it ran; one that ignores that is killed ``killDelay`` later. `nil` if
    /// it couldn't be started or was cancelled first.
    public static func result(of executable: URL, arguments: [String]) async -> Result? {
        let running = RunningTool()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process()
                    let output = Pipe()
                    let error = Pipe()
                    process.executableURL = executable
                    process.arguments = arguments
                    process.standardOutput = output
                    process.standardError = error
                    // Foundation reaps the tool, then calls this: its process ID is never signalled after that.
                    process.terminationHandler = { _ in running.finish() }
                    guard running.launch(process) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    // Both pipes are drained at once, so a tool that fills one while we read the other can't stall.
                    let errorData = Mutex(Data())
                    let readingError = DispatchGroup()
                    DispatchQueue.global(qos: .utility).async(group: readingError) {
                        let data = error.fileHandleForReading.readDataToEndOfFile()
                        errorData.withLock { $0 = data }
                    }
                    let outputData = output.fileHandleForReading.readDataToEndOfFile()
                    readingError.wait()
                    process.waitUntilExit()
                    continuation.resume(
                        returning: Result(
                            status: process.terminationStatus, output: outputData,
                            error: errorData.withLock { $0 }))
                }
            }
        } onCancel: {
            running.cancel()
        }
    }
}

/// A tool started by ``ProcessRunner/result(of:arguments:)``, by process ID, for cancelling it from another thread.
private final class RunningTool: Sendable {
    private struct State {
        var pid: pid_t = 0
        var isCancelled = false
    }

    private let state = Mutex(State())

    /// Starts `process` unless cancelled already.
    func launch(_ process: Process) -> Bool {
        state.withLock { state in
            guard !state.isCancelled, (try? process.run()) != nil else { return false }
            state.pid = process.processIdentifier
            return true
        }
    }

    /// Called once the process has exited and been reaped, from its termination handler.
    func finish() {
        state.withLock { $0.pid = 0 }
    }

    /// Asks the tool to exit, and kills it if it's still running a moment later. Signals go out under the same lock
    /// ``finish()`` takes, so never to a process ID that's been reaped.
    func cancel() {
        let pid = state.withLock { state in
            state.isCancelled = true
            if state.pid > 0 { kill(state.pid, SIGTERM) }
            return state.pid
        }
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ProcessRunner.killDelay) { [self] in
            state.withLock { state in
                if state.pid == pid { kill(pid, SIGKILL) }
            }
        }
    }
}
