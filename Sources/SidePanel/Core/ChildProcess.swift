import Foundation
import Darwin
import CoreServices
import Combine

// MARK: - Child process in its own process group (killpg cleans up grandchildren too)

final class ChildProcess {
    let pid: pid_t
    private let stdinFD: Int32
    private let out: FileHandle
    private var buf = Data()

    /// Spawns `path args` with POSIX_SPAWN_SETPGROUP (new group, pgid == pid) and POSIX_SPAWN_CLOEXEC_DEFAULT
    /// (child inherits only stdin/stdout/stderr, not our listening socket etc.). stdout is split into lines.
    static func spawn(_ path: String, _ args: [String], onLine: @escaping (Data) -> Void, onExit: @escaping () -> Void) -> ChildProcess? {
        var inP: [Int32] = [0, 0], outP: [Int32] = [0, 0]
        guard pipe(&inP) == 0, pipe(&outP) == 0 else { return nil }
        let devnull = open("/dev/null", O_WRONLY)
        var fa: posix_spawn_file_actions_t? = nil; posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_adddup2(&fa, inP[0], 0)
        posix_spawn_file_actions_adddup2(&fa, outP[1], 1)
        posix_spawn_file_actions_adddup2(&fa, devnull, 2)
        var attr: posix_spawnattr_t? = nil; posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr) }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &fa, &attr, argv, environ)
        close(inP[0]); close(outP[1]); close(devnull)
        guard rc == 0 else { close(inP[1]); close(outP[0]); return nil }
        DispatchQueue.global(qos: .utility).async { var st: Int32 = 0; waitpid(pid, &st, 0) } // reap, no zombies
        let c = ChildProcess(pid: pid, stdinFD: inP[1], out: FileHandle(fileDescriptor: outP[0], closeOnDealloc: true))
        c.out.readabilityHandler = { [weak c] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; onExit(); return }
            guard let c else { return }
            c.buf.append(d)
            while let nl = c.buf.firstIndex(of: 0x0A) {
                let line = c.buf.subdata(in: c.buf.startIndex..<nl)
                c.buf.removeSubrange(c.buf.startIndex...nl)
                if !line.isEmpty { onLine(line) }
            }
        }
        return c
    }
    private init(pid: pid_t, stdinFD: Int32, out: FileHandle) { self.pid = pid; self.stdinFD = stdinFD; self.out = out }

    func send(_ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        d.append(0x0A)
        _ = d.withUnsafeBytes { write(stdinFD, $0.baseAddress, d.count) }
    }
    func killGroup() {
        close(stdinFD)
        killpg(pid, SIGTERM)
    }
}

