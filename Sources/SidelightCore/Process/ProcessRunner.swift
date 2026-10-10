import Foundation

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
}
