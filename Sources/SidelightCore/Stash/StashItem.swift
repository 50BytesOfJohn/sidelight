import Foundation

/// One thing someone stashed: a prompt to use next, a snippet to reuse, a note. Plain text; the first line is its
/// title.
///
/// Done is a date rather than a flag, so an item can't be done without saying when, which deleting done items goes by. Pinned
/// items are reusable snippets: they sort first and never get marked done.
public struct StashItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var text: String
    public var createdAt: Date
    public var updatedAt: Date
    /// The bundle identifier of the app it came from, shown as that app's icon; `nil` when it was typed in or the
    /// app isn't known.
    public var source: String?
    public var isPinned: Bool
    /// When it was marked done; `nil` while it's open.
    public var doneAt: Date?

    public init(
        id: UUID = UUID(), text: String, createdAt: Date, updatedAt: Date? = nil, source: String? = nil,
        isPinned: Bool = false, doneAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.source = source
        self.isPinned = isPinned
        self.doneAt = isPinned ? nil : doneAt
    }

    public var isDone: Bool { doneAt != nil }

    /// The first line with any text, trimmed.
    public var title: String {
        let line = text.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }
        return line.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// Whether every word of `query` appears in its text, ignoring case and accents. An empty query matches.
    public func matches(_ query: StashSearch) -> Bool {
        query.terms.allSatisfy { text.localizedStandardContains($0) }
    }
}

/// A search as typed, split into the words every match must contain.
public struct StashSearch: Hashable, Sendable {
    public let terms: [String]

    public init(_ text: String) {
        terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public var isEmpty: Bool { terms.isEmpty }
}

/// Stored as `{"id", "text", "createdAt", "updatedAt", "source", "pinned", "doneAt"}`. Only `id` and `text` are
/// required, so an item written by hand, or by a later version that drops a field, still loads. Encoding is
/// synthesized, and leaves out `source` and `doneAt` when they're `nil`.
extension StashItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, text, createdAt, updatedAt, source, doneAt
        case isPinned = "pinned"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt = container.decodeLeniently(.createdAt, or: Date.now)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            text: try container.decode(String.self, forKey: .text),
            createdAt: createdAt,
            updatedAt: container.decodeLeniently(.updatedAt, or: createdAt),
            source: container.decodeLeniently(.source, or: nil),
            isPinned: container.decodeLeniently(.isPinned, or: false),
            doneAt: container.decodeLeniently(.doneAt, or: nil))
    }
}
