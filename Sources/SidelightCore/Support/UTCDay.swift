import Foundation

/// A calendar day in UTC, the way providers that bill by the day count them: the same everywhere, whatever the
/// time zone of the Mac.
public struct UTCDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// The day `date` falls on in UTC.
    public init(_ date: Date) {
        let components = Self.calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 1970
        month = components.month ?? 1
        day = components.day ?? 1
    }

    /// `2026-10-08`, or a timestamp starting with one (`2026-10-08 00:00:00`, `2026-10-08T00:00:00Z`). `nil` for
    /// anything else, including dates that don't exist.
    public init?(iso text: String) {
        let parts = text.prefix(10).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        guard components.isValidDate(in: Self.calendar) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Midnight at the start of the day, UTC.
    public var start: Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    /// The day `count` days later (earlier, for a negative count).
    public func adding(days count: Int) -> UTCDay {
        UTCDay(Self.calendar.date(byAdding: .day, value: count, to: start) ?? start)
    }

    /// `2026-10-08`
    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: UTCDay, rhs: UTCDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}
