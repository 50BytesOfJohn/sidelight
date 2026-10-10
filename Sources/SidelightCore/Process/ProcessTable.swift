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

    private static func info(of pid: Int32) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }
}
