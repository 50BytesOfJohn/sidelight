import Foundation
import Darwin

// MARK: - Paths / logging

let logDir: URL = {
    let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SidePanelNative")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()
let isoFmt: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

func appendLog(_ name: String, _ line: String) {
    let url = logDir.appendingPathComponent(name)
    let data = (isoFmt.string(from: Date()) + " " + line + "\n").data(using: .utf8)!
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
    else { try? data.write(to: url) }
    print(line)
}

func processStartTime() -> Date {
    var kp = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    sysctl(&mib, 4, &kp, &size, nil, 0)
    let tv = kp.kp_proc.p_un.__p_starttime
    return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
}

