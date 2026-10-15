import Foundation

/// Keeps a copy of a file Sidelight owns before replacing it, next to it, named for why and when:
/// `config.invalid-2026-10-15T09-30-00.json`. An earlier backup is never replaced.
enum FileBackup {
    /// Writes `data` beside `fileURL` as a backup for `reason`, returning where. Throws when it can't be written.
    nonisolated static func keep(_ data: Data, besides fileURL: URL, as reason: String) throws -> URL {
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacing(":", with: "-")
        let extensionName = fileURL.pathExtension
        for attempt in 1...20 {
            let name = attempt == 1 ? "\(reason)-\(stamp)" : "\(reason)-\(stamp)-\(attempt)"
            let backup = fileURL.deletingPathExtension().appendingPathExtension("\(name).\(extensionName)")
            do {
                try data.write(to: backup, options: .withoutOverwriting)
                return backup
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
