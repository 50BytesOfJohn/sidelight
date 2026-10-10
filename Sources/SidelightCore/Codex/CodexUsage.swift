import Foundation

/// Rate limits as reported by `codex app-server` (camelCase) or a rollout file (snake_case).
public struct CodexRateLimits: Equatable, Sendable {
    /// The 5-hour window.
    public var primary: RateLimitWindow?
    /// The weekly window.
    public var secondary: RateLimitWindow?
    public var planType: String?

    public init(primary: RateLimitWindow? = nil, secondary: RateLimitWindow? = nil, planType: String? = nil) {
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
    }
}

/// Token usage from `account/usage/read`.
public struct CodexUsage: Equatable, Sendable {
    public var lifetimeTokens: Int64?
    /// Tokens per local calendar day, keyed `yyyy-MM-dd`.
    public var tokensByDay: [String: Int64]

    public init(lifetimeTokens: Int64? = nil, tokensByDay: [String: Int64] = [:]) {
        self.lifetimeTokens = lifetimeTokens
        self.tokensByDay = tokensByDay
    }

    public func tokens(on date: Date, calendar: Calendar = .autoupdatingCurrent) -> Int64 {
        tokensByDay[Self.dayKey(for: date, calendar: calendar)] ?? 0
    }

    /// Daily totals for the `days` days ending on `date` (inclusive), oldest first.
    public func dailyTotals(endingOn date: Date, days: Int, calendar: Calendar = .autoupdatingCurrent) -> [Int64] {
        let lastDay = calendar.startOfDay(for: date)
        return (0..<days).reversed().map { offset in
            calendar.date(byAdding: .day, value: -offset, to: lastDay).map { tokens(on: $0, calendar: calendar) } ?? 0
        }
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

// MARK: - Decoding

extension RateLimitWindow: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        self.init(
            usedPercent: container.lenientDouble("usedPercent", "used_percent") ?? 0,
            resetsAt: container.lenientDouble("resetsAt", "resets_at").map(Date.init(timeIntervalSince1970:)),
            durationMinutes: container.lenientInt64("windowDurationMins", "window_minutes").map(Int.init)
        )
    }
}

extension CodexRateLimits: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        self.init(
            primary: container.lenient(RateLimitWindow.self, "primary"),
            secondary: container.lenient(RateLimitWindow.self, "secondary"),
            planType: container.lenient(String.self, "planType", "plan_type")
        )
    }
}
