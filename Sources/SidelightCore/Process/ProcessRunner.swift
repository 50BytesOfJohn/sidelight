import Darwin
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
                    guard let pipes = running.launch(executable, arguments: arguments) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    // Both pipes are drained at once, so a tool that fills one while we read the other can't stall.
                    let errorData = Mutex(Data())
                    let readingError = DispatchGroup()
                    DispatchQueue.global(qos: .utility).async(group: readingError) {
                        let data = pipes.error.readDataToEndOfFile()
                        errorData.withLock { $0 = data }
                    }
                    let outputData = pipes.output.readDataToEndOfFile()
                    readingError.wait()
                    continuation.resume(
                        returning: Result(
                            status: running.waitUntilExit(), output: outputData, error: errorData.withLock { $0 }))
                }
            }
        } onCancel: {
            running.cancel()
        }
    }
}

/// A tool started by ``ProcessRunner/result(of:arguments:)``, by process ID, for cancelling it from another thread.
///
/// Spawned and reaped here rather than with `Process`: Foundation reaps a `Process` before telling us it exited, and
/// once reaped its ID can go to an unrelated process at any moment. Reaping it ourselves under the lock that guards
/// signals means a signal only ever reaches our own tool, alive or an exited one not yet reaped (whose ID stays
/// reserved).
private final class RunningTool: Sendable {
    private struct State {
        var pid: pid_t = 0
        var isCancelled = false
    }

    private let state = Mutex(State())

    /// Starts the tool unless cancelled already, returning the read ends of its standard output and error.
    func launch(_ executable: URL, arguments: [String]) -> (output: FileHandle, error: FileHandle)? {
        state.withLock { state in
            guard !state.isCancelled, let (pid, output, error) = Self.spawn(executable, arguments: arguments) else {
                return nil
            }
            state.pid = pid
            return (output, error)
        }
    }

    /// Waits for the launched tool to exit, reaps it and returns its exit status, or the signal that ended it (`-1` if
    /// it couldn't be reaped).
    func waitUntilExit() -> Int32 {
        let pid = state.withLock { $0.pid }
        // Wait without reaping, so the process ID can't be reused while `cancel()` may still signal it.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0, errno == EINTR {}
        var status: Int32 = 0
        let reaped = state.withLock { state in
            state.pid = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
            return result == pid
        }
        guard reaped else { return -1 }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
    }

    /// Asks the tool to exit, and kills it if it's still running a moment later. Signals go out under the same lock
    /// ``waitUntilExit()`` reaps under, so never to a process ID that's been reaped.
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

    /// Spawns `executable` with standard input from `/dev/null`, our environment and default signal handling, and
    /// no descriptors of ours beyond the three standard ones.
    private static func spawn(_ executable: URL, arguments: [String]) -> (pid_t, FileHandle, FileHandle)? {
        var outputPipe: [Int32] = [-1, -1]
        var errorPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0 else { return nil }
        guard pipe(&errorPipe) == 0 else {
            close(outputPipe[0])
            close(outputPipe[1])
            return nil
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errorPipe[1], STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        var noSignals = sigset_t()
        var allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        let path = executable.path(percentEncoded: false)
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &fileActions, &attributes, argv, environ)
        close(outputPipe[1])
        close(errorPipe[1])
        guard result == 0 else {
            close(outputPipe[0])
            close(errorPipe[0])
            return nil
        }
        return (
            pid, FileHandle(fileDescriptor: outputPipe[0], closeOnDealloc: true),
            FileHandle(fileDescriptor: errorPipe[0], closeOnDealloc: true)
        )
    }
}
