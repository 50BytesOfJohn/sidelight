import Foundation

/// Timestamps as the tools and services Sidelight reads write them.
extension Date {
    private static let wholeSeconds = Date.ISO8601FormatStyle()
    private static let fractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// ISO 8601, with or without fractions of a second. Fractions longer than the parser takes are dropped.
    public init?(iso8601 text: String) {
        guard
            let date = (try? Self.fractionalSeconds.parse(text)) ?? (try? Self.wholeSeconds.parse(text))
                ?? (try? Self.wholeSeconds.parse(text.replacing(/\.\d+/, with: "", maxReplacements: 1)))
        else { return nil }
        self = date
    }

    /// Milliseconds since 1970, as JavaScript and SQLite timestamps count.
    public init(millisecondsSince1970 milliseconds: Double) {
        self.init(timeIntervalSince1970: milliseconds / 1000)
    }
}
