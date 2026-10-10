import Foundation
import Synchronization

/// Runs short-lived command-line tools without blocking a thread while they run.
public enum ProcessRunner {
    /// Runs `executable` to completion and returns its exit status (or `-1` if it couldn't be started).
    public static func run(_ executable: URL, arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
    }

    /// Runs `executable` to completion and returns what it wrote to standard output, or `nil` if it couldn't be
    /// started or exited with an error. For tools with short output.
    public static func output(of executable: URL, arguments: [String]) async -> Data? {
        await withCheckedContinuation { continuation in
            // Reading until the tool closes its output blocks, so it waits on a GCD thread rather than one of
            // Swift concurrency's few.
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let output = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
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
    /// the person) doesn't outlive the reason it ran. `nil` if it couldn't be started or was cancelled first.
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
                    running.finish()
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

    /// Called as soon as the process has exited.
    func finish() {
        state.withLock { $0.pid = 0 }
    }

    func cancel() {
        state.withLock { state in
            state.isCancelled = true
            if state.pid > 0 { kill(state.pid, SIGTERM) }
        }
    }
}
