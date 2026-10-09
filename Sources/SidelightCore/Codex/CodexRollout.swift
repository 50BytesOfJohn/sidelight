import Foundation

/// What the newest Codex session log ("rollout" file) says about rate limits.
///
/// Fallback for when `codex app-server` is unavailable: Codex appends a `token_count` event with the current
/// rate limits to `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` after every turn.
public struct CodexRolloutSnapshot: Equatable, Sendable {
    public var rateLimits: CodexRateLimits
    /// Total tokens used by that session.
    public var sessionTokens: Int64?

    public init(rateLimits: CodexRateLimits, sessionTokens: Int64? = nil) {
        self.rateLimits = rateLimits
        self.sessionTokens = sessionTokens
    }
}

public enum CodexRollout {
    /// Only the end of the file is read; the latest `token_count` event is always near it.
    public static let tailSize = 512 * 1024

    public static var defaultSessionsDirectory: URL {
        URL.homeDirectory.appending(path: ".codex/sessions", directoryHint: .isDirectory)
    }

    /// Reads the newest rollout file under `sessionsDirectory` and returns its latest snapshot.
    public static func latestSnapshot(sessionsDirectory: URL = defaultSessionsDirectory) -> CodexRolloutSnapshot? {
        guard let file = newestRolloutFile(in: sessionsDirectory), let tail = readTail(of: file) else { return nil }
        return latestSnapshot(inLog: tail)
    }

    /// The last `token_count` event with rate limits in a chunk of rollout JSONL.
    public static func latestSnapshot(inLog log: Data) -> CodexRolloutSnapshot? {
        let marker = Data(#""type":"token_count""#.utf8)
        let decoder = JSONDecoder()
        for line in log.split(separator: 0x0A).reversed() where line.firstRange(of: marker) != nil {
            guard let payload = try? decoder.decode(Line.self, from: Data(line)).payload,
                let rateLimits = payload.rateLimits
            else { continue }
            return CodexRolloutSnapshot(rateLimits: rateLimits, sessionTokens: payload.sessionTokens)
        }
        return nil
    }

    /// The most recently modified `rollout-*.jsonl` in the newest `YYYY/MM/DD` directory that has one.
    public static func newestRolloutFile(in sessionsDirectory: URL, fileManager: FileManager = .default) -> URL? {
        func numberedSubdirectories(of directory: URL) -> [URL] {
            let names = (try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
            return names.filter { Int($0) != nil }.sorted(by: >).map {
                directory.appending(path: $0, directoryHint: .isDirectory)
            }
        }

        for year in numberedSubdirectories(of: sessionsDirectory) {
            for month in numberedSubdirectories(of: year) {
                for day in numberedSubdirectories(of: month) {
                    let files =
                        (try? fileManager.contentsOfDirectory(
                            at: day,
                            includingPropertiesForKeys: [.contentModificationDateKey]
                        )) ?? []
                    let newest =
                        files
                        .filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }
                        .max { modificationDate(of: $0) < modificationDate(of: $1) }
                    if let newest { return newest }
                }
            }
        }
        return nil
    }

    static func readTail(of file: URL, maxBytes: Int = tailSize) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
        return try? handle.readToEnd()
    }

    private static func modificationDate(of file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: Wire format

    private struct Line: Decodable {
        var payload: Payload
    }

    private struct Payload: Decodable {
        var rateLimits: CodexRateLimits?
        var sessionTokens: Int64?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            rateLimits = container.lenient(CodexRateLimits.self, "rate_limits")
            sessionTokens = container.lenient(Info.self, "info")?.totalTokens
        }
    }

    private struct Info: Decodable {
        var totalTokens: Int64?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            totalTokens = container.lenient(Usage.self, "total_token_usage")?.totalTokens
        }
    }

    private struct Usage: Decodable {
        var totalTokens: Int64?

        init(from decoder: any Decoder) throws {
            totalTokens = try decoder.container(keyedBy: AnyCodingKey.self).lenientInt64("total_tokens")
        }
    }
}
