import Darwin
import Foundation

/// Facts about other processes, by process ID, from the kernel's process table.
public enum ProcessTable {
    /// When the process with `pid` started; `nil` when there's no such process.
    public static func startDate(of pid: Int32) -> Date? {
        guard let info = info(of: pid) else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    /// The process with `pid` is running and started no later than `date`, so it's the one that wrote a record at
    /// `date` and not a newer process that was given the same ID after it exited.
    public static func isRunning(_ pid: Int32, startedBy date: Date) -> Bool {
        guard let start = startDate(of: pid) else { return false }
        // Start times are whole microseconds; the record's are whole milliseconds.
        return start <= date.addingTimeInterval(1)
    }

    /// The process that started `pid`; `nil` for launchd and for processes that are gone.
    public static func parent(of pid: Int32) -> Int32? {
        guard let parent = info(of: pid)?.kp_eproc.e_ppid, parent > 1 else { return nil }
        return parent
    }

    /// `pid` and the processes that started it, nearest first, up to `limit` of them.
    public static func ancestry(of pid: Int32, limit: Int = 12) -> [Int32] {
        Array(sequence(first: pid, next: parent(of:)).prefix(limit))
    }

    /// The terminal the process runs in, such as `/dev/ttys003`; `nil` when it has none.
    public static func terminalPath(of pid: Int32) -> String? {
        // -1 is NODEV, which Swift doesn't import.
        guard let device = info(of: pid)?.kp_eproc.e_tdev, device != -1,
            let name = devname(device, S_IFCHR)
        else { return nil }
        return "/dev/" + String(cString: name)
    }

    /// Every process running now, in one read of the kernel's table; `nil` when the table can't be read, which
    /// isn't the same as no processes.
    public static func snapshot() -> [ProcessEntry]? {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        // Room for processes that start between the two reads.
        size += size / 8
        var infos = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&name, 3, &infos, &size, nil, 0) == 0 else { return nil }
        return infos.prefix(size / MemoryLayout<kinfo_proc>.stride).map { info in
            let start = info.kp_proc.p_un.__p_starttime
            let command = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            return ProcessEntry(
                pid: info.kp_proc.p_pid,
                parent: info.kp_eproc.e_ppid,
                startedAt: Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000),
                name: command
            )
        }
    }

    /// The files `pid` has open whose paths start with `prefix`. Only the user's own processes can be asked. The
    /// kernel reports paths with symbolic links resolved, so `prefix` is resolved too.
    public static func openFiles(of pid: Int32, withPrefix prefix: String) -> [String] {
        let prefix = resolved(prefix)
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Room for files opened between the two reads.
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / stride + 16)
        let filled = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        var paths: [String] = []
        for descriptor in descriptors.prefix(Int(filled) / stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else {
                continue
            }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if path.hasPrefix(prefix) { paths.append(path) }
        }
        return paths
    }

    /// The arguments `pid` was started with, its executable's name first; `nil` when they can't be read, as for
    /// other users' processes.
    public static func arguments(of pid: Int32) -> [String]? {
        guard pid > 0 else { return nil }
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        // The argument count, the executable's path, padding, then each argument; all strings end in a zero byte.
        let count = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var strings = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true)
        guard !strings.isEmpty else { return nil }
        strings.removeFirst()
        return strings.prefix(count).map { String(decoding: $0, as: UTF8.self) }
    }

    /// `path` with symbolic links resolved, keeping a trailing slash; unchanged when it doesn't exist.
    private static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        let resolved = String(cString: real)
        return path.hasSuffix("/") && !resolved.hasSuffix("/") ? resolved + "/" : resolved
    }

    private static func info(of pid: Int32) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }
}

/// One process in a ``ProcessTable/snapshot()``.
public struct ProcessEntry: Hashable, Sendable {
    public var pid: Int32
    public var parent: Int32
    public var startedAt: Date
    /// The executable's name, cut to 16 characters: `codex`, `zsh`.
    public var name: String

    public init(pid: Int32, parent: Int32, startedAt: Date, name: String) {
        self.pid = pid
        self.parent = parent
        self.startedAt = startedAt
        self.name = name
    }
}

extension [ProcessEntry] {
    /// The processes started by `pid`, and by those, and so on, `pid` itself left out.
    public func descendants(of pid: Int32) -> [ProcessEntry] {
        let children = Dictionary(grouping: self, by: \.parent)
        var found: [ProcessEntry] = []
        var queue = [pid]
        var seen: Set<Int32> = [pid]
        while let next = queue.popLast() {
            for child in children[next] ?? [] where seen.insert(child.pid).inserted {
                found.append(child)
                queue.append(child.pid)
            }
        }
        return found
    }
}
