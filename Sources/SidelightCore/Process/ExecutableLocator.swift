import Foundation

/// Finds command-line tools installed by Homebrew and friends.
///
/// Apps launched from Finder or at login get a minimal `PATH`, so we look in the usual install locations
/// ourselves instead of relying on it.
public enum ExecutableLocator {
    public static var standardDirectories: [URL] {
        [
            URL(filePath: "/opt/homebrew/bin", directoryHint: .isDirectory),
            URL(filePath: "/usr/local/bin", directoryHint: .isDirectory),
            URL.homeDirectory.appending(path: ".local/bin", directoryHint: .isDirectory),
        ]
    }

    public static func find(
        _ name: String,
        in directories: [URL] = standardDirectories,
        fileManager: FileManager = .default
    ) -> URL? {
        directories
            .map { $0.appending(path: name, directoryHint: .notDirectory) }
            .first { fileManager.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }
}
