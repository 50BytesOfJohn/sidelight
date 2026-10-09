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
}
