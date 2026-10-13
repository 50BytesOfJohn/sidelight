import Foundation

/// Whose spending a chart shows: the account's, across its workspaces, or one API key's.
public enum OpenRouterSpendScope: Hashable, Sendable {
    case account
    /// The key with this hash. Keys are chosen by hash, which stays the same when a key is renamed.
    case key(String)
}

/// The account's credits: what was bought and what was used, in US dollars. Not a key's spending limit.
public struct OpenRouterBalance: Equatable, Sendable {
    public let totalCredits: Decimal
    public let totalUsage: Decimal
    public let fetchedAt: Date

    public init(totalCredits: Decimal, totalUsage: Decimal, fetchedAt: Date) {
        self.totalCredits = totalCredits
        self.totalUsage = totalUsage
        self.fetchedAt = fetchedAt
    }

    /// What's left to spend. Below zero when usage ran past the credits bought, and shown that way.
    public var remaining: Decimal { totalCredits - totalUsage }
}

/// One completed UTC day of spending.
public struct OpenRouterSpendDay: Equatable, Identifiable, Sendable {
    public let day: UTCDay
    /// Charged to the credits that day; `nil` when OpenRouter reported nothing for it.
    public let usage: Decimal?
    /// Inference other providers billed through your own keys (BYOK): not taken from the credits, so never added to
    /// ``usage``. `nil` when none was reported.
    public let byokUsage: Decimal?

    public init(day: UTCDay, usage: Decimal?, byokUsage: Decimal?) {
        self.day = day
        self.usage = usage
        self.byokUsage = byokUsage
    }

    public var id: UTCDay { day }

    /// Whether OpenRouter reported any activity that day.
    public var isReported: Bool { usage != nil }
}

/// Spending by day over the last 30 completed UTC days, for the account or one key, as OpenRouter reported it in
/// one answer. Today never counts: it isn't over yet, and OpenRouter doesn't report it.
public struct OpenRouterActivity: Equatable, Sendable {
    /// OpenRouter reports this many completed days.
    public static let reportedDays = 30

    /// Credit usage and BYOK usage summed over every row of each day.
    private let byDay: [UTCDay: (usage: Decimal, byok: Decimal?)]
    /// The most recent day covered: the day before the answer, in UTC.
    public let lastCompletedDay: UTCDay
    public let fetchedAt: Date
    /// The key it was scoped to, as OpenRouter described it when asked; `nil` for the account.
    public let key: OpenRouterKey?

    public init(rows: [(day: UTCDay, usage: Decimal, byok: Decimal?)], fetchedAt: Date, key: OpenRouterKey? = nil) {
        let lastCompletedDay = UTCDay(fetchedAt).adding(days: -1)
        let firstDay = lastCompletedDay.adding(days: -(Self.reportedDays - 1))
        var byDay: [UTCDay: (usage: Decimal, byok: Decimal?)] = [:]
        for row in rows where row.day >= firstDay && row.day <= lastCompletedDay {
            let current = byDay[row.day]
            let byok: Decimal? =
                switch (current?.byok, row.byok) {
                case (nil, nil): nil
                case (let sum?, nil), (nil, let sum?): sum
                case (let sum?, let more?): sum + more
                }
            byDay[row.day] = ((current?.usage ?? 0) + row.usage, byok)
        }
        self.byDay = byDay
        self.lastCompletedDay = lastCompletedDay
        self.fetchedAt = fetchedAt
        self.key = key
    }

    /// The last `count` completed days this answer covers, oldest first. Days without rows are there, unreported.
    public func days(_ count: Int) -> [OpenRouterSpendDay] {
        let count = count.clamped(to: 1...Self.reportedDays)
        return (0..<count).reversed().map { offset in
            let day = lastCompletedDay.adding(days: -offset)
            let totals = byDay[day]
            return OpenRouterSpendDay(day: day, usage: totals?.usage, byokUsage: totals?.byok)
        }
    }

    /// What `days` charged to the credits together: only reported days count.
    public static func total(of days: [OpenRouterSpendDay]) -> Decimal {
        days.reduce(0) { $0 + ($1.usage ?? 0) }
    }

    /// BYOK inference over `days`, kept apart from the credits; `nil` when none was reported.
    public static func byokTotal(of days: [OpenRouterSpendDay]) -> Decimal? {
        let reported = days.compactMap(\.byokUsage)
        return reported.isEmpty ? nil : reported.reduce(0, +)
    }

    /// Whether days have ended since: the chart is missing the most recent ones until it's fetched again.
    public func isBehind(at now: Date) -> Bool {
        lastCompletedDay < UTCDay(now).adding(days: -1)
    }

    public static func == (lhs: OpenRouterActivity, rhs: OpenRouterActivity) -> Bool {
        lhs.lastCompletedDay == rhs.lastCompletedDay && lhs.fetchedAt == rhs.fetchedAt && lhs.key == rhs.key
            && lhs.days(reportedDays) == rhs.days(reportedDays)
    }
}

/// One of the account's API keys, as the key list describes it. Never the key itself: OpenRouter only shows that
/// once, when it's created.
public struct OpenRouterKey: Identifiable, Hashable, Sendable {
    public let hash: String
    /// The name given to it, or OpenRouter's masked label when it has none.
    public let name: String
    public let isDisabled: Bool
    public let expiresAt: Date?

    public init(hash: String, name: String, isDisabled: Bool = false, expiresAt: Date? = nil) {
        self.hash = hash
        self.name = name
        self.isDisabled = isDisabled
        self.expiresAt = expiresAt
    }

    public var id: String { hash }

    public func isExpired(at now: Date) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }
}

/// What OpenRouter says about a key someone is about to save.
public struct OpenRouterKeyCheck: Equatable, Sendable {
    /// Management keys can read the account's credits and activity, and also create, change and delete keys.
    /// `nil` when OpenRouter didn't say.
    public let isManagementKey: Bool?
    public let label: String?

    public init(isManagementKey: Bool?, label: String?) {
        self.isManagementKey = isManagementKey
        self.label = label
    }
}
