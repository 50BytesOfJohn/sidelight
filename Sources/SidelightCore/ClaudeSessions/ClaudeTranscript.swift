import Foundation

/// A Claude Code session's transcript, `~/.claude/projects/<folder>/<session>.jsonl`, read only for the session's
/// title. Claude Code appends the title every so often as it changes: `custom-title` after `/rename`, `ai-title`
/// once it has summarized the conversation.
public enum ClaudeTranscript {
    public static let defaultProjectsDirectory = URL.homeDirectory.appending(
        path: ".claude/projects", directoryHint: .isDirectory)

    /// How much of each end of the file is read. Transcripts reach tens of megabytes.
    public static let chunkSize = 64 * 1024

    /// The transcript of `sessionID`, started in `cwd`. Claude Code names the folder after the working directory with
    /// every character but letters and digits turned into `-`; when that guess misses (very long paths are shortened
    /// with a hash), every project folder is looked in.
    public static func url(sessionID: String, cwd: String?, projectsDirectory: URL = defaultProjectsDirectory) -> URL? {
        let fileName = "\(sessionID).jsonl"
        let fileManager = FileManager.default
        if let cwd {
            let folder = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            let url = projectsDirectory.appending(path: folder, directoryHint: .isDirectory).appending(path: fileName)
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        }
        let folders =
            (try? fileManager.contentsOfDirectory(
                at: projectsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return folders.lazy.map { $0.appending(path: fileName) }
            .first { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    /// The newest title in the last ``chunkSize`` of the file, or else the first ``chunkSize``. Without one, the
    /// latest prompt, as Claude Code's own session list does.
    public static func title(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let tailStart = end > UInt64(chunkSize) ? end - UInt64(chunkSize) : 0
        try? handle.seek(toOffset: tailStart)
        let tail = (try? handle.read(upToCount: chunkSize)).map(Titles.init(in:))
        if let title = tail?.title { return title }
        guard tailStart > 0 else { return tail?.prompt }
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: chunkSize)).map(Titles.init(in:))
        return head?.title ?? tail?.prompt ?? head?.prompt
    }

    /// The newest title among the JSON lines in `data`, a name set by the user winning over a generated one.
    public static func title(in data: Data) -> String? {
        Titles(in: data).title
    }

    /// What a stretch of transcript says the session is about. Lines cut off at either end are skipped.
    struct Titles {
        var custom: String?
        var generated: String?
        var prompt: String?

        var title: String? { custom ?? generated }

        init(in data: Data) {
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard markers.contains(where: { line.firstRange(of: $0) != nil }),
                    let entry = try? JSONDecoder().decode(TitleEntry.self, from: line)
                else { continue }
                switch entry.type {
                case "custom-title": custom = entry.customTitle.flatMap(ClaudeTranscript.oneLine) ?? custom
                case "ai-title": generated = entry.aiTitle.flatMap(ClaudeTranscript.oneLine) ?? generated
                case "last-prompt": prompt = entry.lastPrompt.flatMap(ClaudeTranscript.oneLine) ?? prompt
                default: break
                }
            }
        }
    }

    /// Only lines with one of these are decoded; the rest are messages, often large.
    private static let markers = [Data("-title\"".utf8), Data("\"last-prompt\"".utf8)]

    private struct TitleEntry: Decodable {
        var type: String
        var customTitle: String?
        var aiTitle: String?
        var lastPrompt: String?
    }

    /// Runs of whitespace and line breaks as single spaces; `nil` when nothing's left.
    private static func oneLine(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
