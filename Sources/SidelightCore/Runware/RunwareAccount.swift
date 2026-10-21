import Foundation

/// A Runware organization's balance. Free credits are kept apart and never added: whether ``amount`` already
/// includes them isn't documented.
public struct RunwareBalance: Equatable, Sendable {
    public let amount: Decimal
    /// Promotional credits; `nil` when Runware didn't say.
    public let freeBalance: Decimal?
    /// `USD` when Runware didn't say.
    public let currency: String

    public init(amount: Decimal, freeBalance: Decimal? = nil, currency: String = "USD") {
        self.amount = amount
        self.freeBalance = freeBalance
        self.currency = currency
    }
}

/// Spend and requests over one rolling period. Either is `nil` when Runware didn't report it.
public struct RunwareUsageTotal: Equatable, Sendable {
    public let spend: Decimal?
    public let requests: Int?

    public init(spend: Decimal?, requests: Int?) {
        self.spend = spend
        self.requests = requests
    }
}

/// What the organization used today, over the last 7 and 30 days, and ever, as Runware totals it. A period it
/// didn't report is `nil`.
public struct RunwareRollingUsage: Equatable, Sendable {
    public let today: RunwareUsageTotal?
    public let last7Days: RunwareUsageTotal?
    public let last30Days: RunwareUsageTotal?
    public let total: RunwareUsageTotal?

    public init(
        today: RunwareUsageTotal? = nil, last7Days: RunwareUsageTotal? = nil, last30Days: RunwareUsageTotal? = nil,
        total: RunwareUsageTotal? = nil
    ) {
        self.today = today
        self.last7Days = last7Days
        self.last30Days = last30Days
        self.total = total
    }
}

/// One of the organization's API keys, as the account details describe it. Never the key, not even masked.
public struct RunwareAPIKeySummary: Identifiable, Equatable, Sendable {
    public let name: String
    public let isEnabled: Bool
    public let requests: Int?
    public let createdAt: Date?
    public let lastUsedAt: Date?

    public init(
        name: String, isEnabled: Bool = true, requests: Int? = nil, createdAt: Date? = nil, lastUsedAt: Date? = nil
    ) {
        self.name = name
        self.isEnabled = isEnabled
        self.requests = requests
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    /// Runware gives keys no ID in this answer.
    public var id: String { name + (createdAt.map { "@\($0.timeIntervalSince1970)" } ?? "") }
}

/// What `getDetails` says about the organization. Its team (people's names and emails) is never read.
public struct RunwareAccountDetails: Equatable, Sendable {
    public let organizationName: String?
    public let organizationID: String?
    public let balance: RunwareBalance
    public let usage: RunwareRollingUsage
    public let apiKeys: [RunwareAPIKeySummary]
    public let fetchedAt: Date

    public init(
        organizationName: String?, organizationID: String? = nil, balance: RunwareBalance,
        usage: RunwareRollingUsage = .init(), apiKeys: [RunwareAPIKeySummary] = [], fetchedAt: Date
    ) {
        self.organizationName = organizationName
        self.organizationID = organizationID
        self.balance = balance
        self.usage = usage
        self.apiKeys = apiKeys
        self.fetchedAt = fetchedAt
    }

    /// Keys most recently used first; never-used ones last, by name.
    public var keysByLastUse: [RunwareAPIKeySummary] {
        apiKeys.sorted { lhs, rhs in
            switch (lhs.lastUsedAt, rhs.lastUsedAt) {
            case (let lhs?, let rhs?) where lhs != rhs: lhs > rhs
            case (_?, nil): true
            case (nil, _?): false
            default: lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }
}

/// One UTC day of usage.
public struct RunwareDay: Identifiable, Equatable, Sendable {
    public let day: UTCDay
    /// `nil` when Runware reported nothing for the day.
    public let requests: Int?
    /// `nil` when Runware reported nothing, or a spend that couldn't be read.
    public let spend: Decimal?

    public init(day: UTCDay, requests: Int?, spend: Decimal?) {
        self.day = day
        self.requests = requests
        self.spend = spend
    }

    public var id: UTCDay { day }

    /// Whether Runware reported anything for the day.
    public var isReported: Bool { requests != nil || spend != nil }
}

/// One model's usage over a span.
public struct RunwareModelUsage: Identifiable, Equatable, Sendable {
    /// The model's AIR, like `runware:101@1`.
    public let air: String
    /// Its name as Runware gave it; `nil` when it didn't.
    public let name: String?
    public let requests: Int?
    public let spend: Decimal?

    public init(air: String, name: String? = nil, requests: Int?, spend: Decimal?) {
        self.air = air
        self.name = name
        self.requests = requests
        self.spend = spend
    }

    public var id: String { air }

    /// Its name, or its AIR without one.
    public var displayName: String { name ?? air }

    /// By spend, then requests, most first; then by AIR, so the order is stable.
    static func ordered(_ lhs: Self, _ rhs: Self) -> Bool {
        if (lhs.spend ?? 0) != (rhs.spend ?? 0) { return (lhs.spend ?? 0) > (rhs.spend ?? 0) }
        if (lhs.requests ?? 0) != (rhs.requests ?? 0) { return (lhs.requests ?? 0) > (rhs.requests ?? 0) }
        return lhs.air < rhs.air
    }

    /// `rows` summed by AIR, ordered.
    static func summed(_ rows: some Sequence<RunwareActivity.ModelRow>) -> [Self] {
        var byAIR: [String: (name: String?, requests: Int?, spend: Decimal?)] = [:]
        for row in rows {
            let current = byAIR[row.air]
            byAIR[row.air] = (
                current?.name ?? row.name, add(current?.requests, row.requests), add(current?.spend, row.spend)
            )
        }
        return byAIR.map { Self(air: $0.key, name: $0.value.name, requests: $0.value.requests, spend: $0.value.spend) }
            .sorted(by: ordered)
    }
}

/// Both, when either is known.
private func add<Value: AdditiveArithmetic>(_ lhs: Value?, _ rhs: Value?) -> Value? {
    switch (lhs, rhs) {
    case (nil, nil): nil
    case (let value?, nil), (nil, let value?): value
    case (let lhs?, let rhs?): lhs + rhs
    }
}

/// The organization's usage over the last 30 UTC days, today included and still going, as Runware reported it in
/// one answer: by day, and by model.
public struct RunwareActivity: Equatable, Sendable {
    /// Runware reports at most this many days in one answer.
    public static let windowDays = 30

    /// One reported row of the day series.
    public struct Row: Equatable, Sendable {
        public let day: UTCDay
        public let requests: Int?
        public let spend: Decimal?

        public init(day: UTCDay, requests: Int?, spend: Decimal?) {
            self.day = day
            self.requests = requests
            self.spend = spend
        }
    }

    /// One reported row of the model breakdown; `day` when Runware said which day it's for.
    public struct ModelRow: Equatable, Sendable {
        public let day: UTCDay?
        public let air: String
        public let name: String?
        public let requests: Int?
        public let spend: Decimal?

        public init(day: UTCDay? = nil, air: String, name: String? = nil, requests: Int?, spend: Decimal?) {
            self.day = day
            self.air = air
            self.name = name
            self.requests = requests
            self.spend = spend
        }
    }

    /// The days covered, the last being the day it was fetched (UTC).
    public let window: ClosedRange<UTCDay>
    /// Every day of the window, oldest first; days Runware said nothing about are there, unreported.
    public let days: [RunwareDay]
    /// Every model used over the window, by spend.
    public let models: [RunwareModelUsage]
    /// Each day's models, when Runware broke the models down by day too; `nil` when it didn't.
    public let modelsByDay: [UTCDay: [RunwareModelUsage]]?
    public let totalRequests: Int?
    public let totalSpend: Decimal?
    public let fetchedAt: Date

    public init(
        window: ClosedRange<UTCDay>, days rows: [Row], models modelRows: [ModelRow], totalRequests: Int? = nil,
        totalSpend: Decimal? = nil, fetchedAt: Date
    ) {
        self.window = window
        var byDay: [UTCDay: (requests: Int?, spend: Decimal?)] = [:]
        for row in rows where window.contains(row.day) {
            let current = byDay[row.day]
            byDay[row.day] = (add(current?.requests, row.requests), add(current?.spend, row.spend))
        }
        var days: [RunwareDay] = []
        var day = window.lowerBound
        while day <= window.upperBound {
            days.append(RunwareDay(day: day, requests: byDay[day]?.requests, spend: byDay[day]?.spend))
            day = day.adding(days: 1)
        }
        self.days = days
        let inWindow = modelRows.filter { $0.day.map(window.contains) ?? true }
        models = RunwareModelUsage.summed(inWindow)
        let dated = inWindow.filter { $0.day != nil }
        modelsByDay =
            dated.isEmpty ? nil : Dictionary(grouping: dated) { $0.day! }.mapValues { RunwareModelUsage.summed($0) }
        let reported = days.compactMap(\.requests)
        self.totalRequests = totalRequests ?? (reported.isEmpty ? nil : reported.reduce(0, +))
        self.totalSpend = totalSpend
        self.fetchedAt = fetchedAt
    }

    /// The window asked for when fetching at `now`: the last ``windowDays`` UTC days, today included.
    public static func window(endingAt now: Date) -> ClosedRange<UTCDay> {
        let today = UTCDay(now)
        return today.adding(days: -(windowDays - 1))...today
    }

    /// The last `count` days of the window, oldest first.
    public func days(last count: Int) -> [RunwareDay] {
        Array(days.suffix(count.clamped(to: 1...Self.windowDays)))
    }

    /// What `days` spent together: only reported days count.
    public static func spend(of days: [RunwareDay]) -> Decimal {
        days.reduce(0) { $0 + ($1.spend ?? 0) }
    }

    /// How many requests `days` made together.
    public static func requests(of days: [RunwareDay]) -> Int {
        days.reduce(0) { $0 + ($1.requests ?? 0) }
    }

    /// Whether a UTC day has begun since it was fetched: it's missing the newest day until it's fetched again.
    public func isBehind(at now: Date) -> Bool {
        window.upperBound < UTCDay(now)
    }

    /// Whether `day` is the window's last, which was still going when it was fetched.
    public func isPartial(_ day: UTCDay) -> Bool {
        day == window.upperBound
    }
}

/// One day's models, for the History tab.
public struct RunwareDayModels: Equatable, Sendable {
    public let day: UTCDay
    public let models: [RunwareModelUsage]
    public let fetchedAt: Date

    public init(day: UTCDay, models: [RunwareModelUsage], fetchedAt: Date) {
        self.day = day
        self.models = models
        self.fetchedAt = fetchedAt
    }

    /// The models in a one-day `activity`.
    public init(day: UTCDay, activity: RunwareActivity) {
        self.init(
            day: day, models: activity.modelsByDay.map { $0[day] ?? [] } ?? activity.models,
            fetchedAt: activity.fetchedAt)
    }
}
