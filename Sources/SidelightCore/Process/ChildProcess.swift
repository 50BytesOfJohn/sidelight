import Darwin
import Foundation
import Synchronization
import os

/// A helper process (e.g. `codex app-server`, `media-control stream`) speaking newline-delimited text on stdio.
///
/// The child is spawned into its own process group, so ``terminate()`` also takes down any grandchildren it
/// started (`media-control` is a Perl script that forks a second Perl). Only stdin/stdout/stderr are inherited —
/// never our listening sockets or other descriptors.
public final class ChildProcess: Sendable {
    public enum SpawnError: Error {
        case pipeCreationFailed(errno: Int32)
        case spawnFailed(errno: Int32)
    }

    public let processIdentifier: pid_t

    /// Complete lines from the child's stdout. Finishes when the child closes stdout (usually: it exited).
    public let lines: AsyncStream<Data>

    private let standardInput: Mutex<Int32?>
    private let standardOutput: FileHandle
    private let exitSource: any DispatchSourceProcess

    /// Spawns `executable` with `arguments`. stderr goes to `/dev/null`.
    public init(executable: URL, arguments: [String]) throws(SpawnError) {
        var inputPipe: [Int32] = [-1, -1]
        var outputPipe: [Int32] = [-1, -1]
        guard pipe(&inputPipe) == 0 else { throw .pipeCreationFailed(errno: errno) }
        guard pipe(&outputPipe) == 0 else {
            close(inputPipe[0])
            close(inputPipe[1])
            throw .pipeCreationFailed(errno: errno)
        }
        let devNull = open("/dev/null", O_WRONLY)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, inputPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, devNull, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        // New process group (pgid == pid) and close every descriptor not explicitly dup'ed above.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        let path = executable.path(percentEncoded: false)
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &fileActions, &attributes, argv, environ)
        close(inputPipe[0])
        close(outputPipe[1])
        if devNull >= 0 { close(devNull) }
        guard result == 0 else {
            close(inputPipe[1])
            close(outputPipe[0])
            throw .spawnFailed(errno: result)
        }

        // Writing to a child that already exited must fail with EPIPE, not kill us with SIGPIPE.
        _ = fcntl(inputPipe[1], F_SETNOSIGPIPE, 1)

        processIdentifier = pid
        standardInput = Mutex(inputPipe[1])
        standardOutput = FileHandle(fileDescriptor: outputPipe[0], closeOnDealloc: true)

        let (lines, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        self.lines = lines
        let splitter = Mutex(LineSplitter())
        standardOutput.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in splitter.withLock({ $0.append(chunk) }) {
                continuation.yield(line)
            }
        }

        // Reap the child when it exits so it doesn't linger as a zombie.
        exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        exitSource.setEventHandler { [exitSource] in
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            exitSource.cancel()
        }
        exitSource.activate()
    }

    deinit {
        terminate()
    }

    /// Writes `line` to the child's stdin, appending a newline if needed.
    public func send(_ line: Data) {
        var bytes = line
        if bytes.last != 0x0A { bytes.append(0x0A) }
        standardInput.withLock { descriptor in
            guard let descriptor else { return }
            let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if written < 0 {
                Log.process.error("Write to pid \(self.processIdentifier) failed: errno \(errno)")
            }
        }
    }

    /// Closes stdin and sends SIGTERM to the whole process group. Safe to call more than once.
    public func terminate() {
        let descriptor = standardInput.withLock { descriptor in
            defer { descriptor = nil }
            return descriptor
        }
        guard let descriptor else { return }
        close(descriptor)
        killpg(processIdentifier, SIGTERM)
    }
}
