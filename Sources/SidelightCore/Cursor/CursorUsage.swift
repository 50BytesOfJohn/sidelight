import Foundation

/// A Cursor account's included usage for the current billing cycle, as Cursor's Spending dashboard reports it.
///
/// It's the whole account's: the editor, the CLI (`cursor-agent`), cloud agents and Bugbot all draw from the same
/// pools, and Cursor doesn't split them by tool. Since 2026, most plans have two monthly pools
/// (https://cursor.com/help/models-and-usage/usage-limits): **Cursor models** (Auto, Composer and Cursor's own
/// models) and **other models** (third-party models, charged at their API price). Each is reported as a share used;
/// Cursor publishes no size for either, so there are no dollar or token amounts here.
public struct CursorUsage: Equatable, Sendable {
    /// `pro`, `pro_plus`, `ultra`, `free`, `enterprise`…, as Cursor names the plan.
    public var membershipType: String?
    /// `user` for an individual allowance, `team` when it comes from a team plan.
    public var limitType: String?
    public var isUnlimited: Bool
    public var billingCycle: DateInterval?
    /// The included-usage pools, each a window over the billing cycle.
    public var pools: [CursorUsagePool]
    /// Cursor's own blend of both pools (`totalPercentUsed`). Its weighting isn't documented, so it's only shown
    /// when the account has no separate pools.
    public var totalPercentUsed: Double?
    /// Pay-as-you-go usage past the included pools.
    public var onDemand: CursorSpending?
    /// The team's shared on-demand budget, on team plans.
    public var teamOnDemand: CursorSpending?
    public var fetchedAt: Date

    public init(
        membershipType: String? = nil, limitType: String? = nil, isUnlimited: Bool = false,
        billingCycle: DateInterval? = nil, pools: [CursorUsagePool] = [], totalPercentUsed: Double? = nil,
        onDemand: CursorSpending? = nil, teamOnDemand: CursorSpending? = nil, fetchedAt: Date
    ) {
        self.membershipType = membershipType
        self.limitType = limitType
        self.isUnlimited = isUnlimited
        self.billingCycle = billingCycle
        self.pools = pools
        self.totalPercentUsed = totalPercentUsed
        self.onDemand = onDemand
        self.teamOnDemand = teamOnDemand
        self.fetchedAt = fetchedAt
    }

    /// `Pro+`, `Ultra`, `Hobby`…; `nil` when Cursor didn't say.
    public var planName: String? { membershipType.flatMap(Self.planName(membershipType:)) }

    /// The pool closest to running out: the one that limits you first.
    public var tightestPool: CursorUsagePool? {
        pools.reduce(nil) { tightest, pool in
            guard let tightest else { return pool }
            return pool.window.usedPercent > tightest.window.usedPercent ? pool : tightest
        }
    }

    /// Whether the billing cycle this was fetched in has ended by `now`.
    public func cycleHasEnded(at now: Date) -> Bool {
        billingCycle.map { $0.end <= now } ?? false
    }

    /// The usage as it stands at `now`: once the billing cycle has ended, the pools start again from zero. Billing
    /// months differ in length, so the next cycle's end stays unknown until the next fetch.
    public func current(at now: Date) -> CursorUsage {
        guard cycleHasEnded(at: now) else { return self }
        var usage = self
        usage.pools = pools.map { pool in
            var pool = pool
            pool.window = pool.window.current(at: now, resetsOnSchedule: false)
            pool.message = nil
            return pool
        }
        usage.totalPercentUsed = totalPercentUsed.map { _ in 0 }
        usage.onDemand?.used = 0
        return usage
    }

    /// `pro_plus` → `Pro+`.
    static func planName(membershipType: String) -> String? {
        let known = [
            "free": "Hobby", "hobby": "Hobby", "free_trial": "Trial", "pro": "Pro", "pro_plus": "Pro+",
            "proplus": "Pro+", "ultra": "Ultra", "team": "Teams", "teams": "Teams", "business": "Teams",
            "enterprise": "Enterprise", "start": "Start",
        ]
        let key = membershipType.lowercased()
        if let name = known[key] { return name }
        let words = key.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
        return words.isEmpty ? nil : words.map(\.capitalized).joined(separator: " ")
    }
}

/// One included-usage pool over the billing cycle.
public struct CursorUsagePool: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        /// Auto, Composer and Cursor's own models (`autoPercentUsed`).
        case cursorModels
        /// Third-party models at their API price (`apiPercentUsed`).
        case otherModels
        /// A single allowance: a team member's (`individualUsage.overall`), or an account with only Cursor's
        /// blended total.
        case included
    }

    public var kind: Kind
    /// Its share used, and the billing cycle as its window.
    public var window: RateLimitWindow
    /// What Cursor itself says about it, such as "You've used 97% of your included API usage".
    public var message: String?

    public var id: Kind { kind }

    public init(kind: Kind, window: RateLimitWindow, message: String? = nil) {
        self.kind = kind
        self.window = window
        self.message = message
    }
}

/// On-demand (pay-as-you-go) spending. Cursor doesn't document the unit of `used` and `limit` (its Admin API counts
/// spend in cents), so Sidelight only shows their ratio, never an amount.
public struct CursorSpending: Equatable, Sendable {
    public var isEnabled: Bool
    public var used: Double?
    /// `nil` without a spending limit.
    public var limit: Double?

    public init(isEnabled: Bool, used: Double? = nil, limit: Double? = nil) {
        self.isEnabled = isEnabled
        self.used = used
        self.limit = limit
    }

    /// The share of the spending limit used, when there is one.
    public var usedPercent: Double? {
        guard let limit, limit > 0 else { return nil }
        return min(max((used ?? 0) / limit * 100, 0), 100)
    }
}

// MARK: - cursor.com/api/usage-summary

extension CursorUsage {
    /// Reads a response of ``CursorUsageAPI``. `nil` when it holds no usage Sidelight can read.
    public init?(usageSummary data: Data, fetchedAt: Date) {
        guard let summary = try? JSONDecoder().decode(UsageSummary.self, from: data),
            !summary.pools.isEmpty || summary.isUnlimited
        else { return nil }
        self.init(
            membershipType: summary.membershipType,
            limitType: summary.limitType,
            isUnlimited: summary.isUnlimited,
            billingCycle: summary.billingCycle,
            pools: summary.pools,
            totalPercentUsed: summary.totalPercentUsed,
            onDemand: summary.onDemand,
            teamOnDemand: summary.teamOnDemand,
            fetchedAt: fetchedAt
        )
    }
}

/// `{"billingCycleStart", "billingCycleEnd", "membershipType", "limitType", "isUnlimited",
/// "autoModelSelectedDisplayMessage", "namedModelSelectedDisplayMessage",
/// "individualUsage": {"plan": {"autoPercentUsed", "apiPercentUsed", "totalPercentUsed", …},
/// "onDemand": {"enabled", "used", "limit"}, "overall": {"used", "limit"}}, "teamUsage": {"onDemand": …}}`
///
/// The schema is the dashboard's own and undocumented, so every part is optional. `plan.used`/`limit` are left
/// alone: they stay 0 on some plans even with real use.
private struct UsageSummary: Decodable {
    var membershipType: String?
    var limitType: String?
    var isUnlimited = false
    var billingCycle: DateInterval?
    var pools: [CursorUsagePool] = []
    var totalPercentUsed: Double?
    var onDemand: CursorSpending?
    var teamOnDemand: CursorSpending?

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: AnyCodingKey.self)
        membershipType = root.lenient(String.self, "membershipType")
        limitType = root.lenient(String.self, "limitType")
        isUnlimited = root.lenient(Bool.self, "isUnlimited") ?? false
        if let start = Self.date(root, "billingCycleStart"), let end = Self.date(root, "billingCycleEnd"), start < end {
            billingCycle = DateInterval(start: start, end: end)
        }
        let cycle = billingCycle
        let window = { (percent: Double) in
            RateLimitWindow(
                usedPercent: min(max(percent, 0), 100),
                resetsAt: cycle?.end,
                durationMinutes: cycle.map { Int(($0.duration / 60).rounded()) }
            )
        }

        let individual = try? root.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("individualUsage"))
        let plan = try? individual?.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("plan"))
        let planEnabled = plan?.lenient(Bool.self, "enabled") ?? true
        if let plan, planEnabled {
            if let auto = plan.lenientDouble("autoPercentUsed") {
                pools.append(
                    CursorUsagePool(
                        kind: .cursorModels, window: window(auto),
                        message: root.lenient(String.self, "autoModelSelectedDisplayMessage")))
            }
            if let api = plan.lenientDouble("apiPercentUsed") {
                pools.append(
                    CursorUsagePool(
                        kind: .otherModels, window: window(api),
                        message: root.lenient(String.self, "namedModelSelectedDisplayMessage")))
            }
            totalPercentUsed = plan.lenientDouble("totalPercentUsed")
        }
        if pools.isEmpty {
            // Team plans report one allowance; accounts without the pools may still have Cursor's total.
            let overall =
                (try? individual?.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("overall")))
                .flatMap(Self.spending)
            if let percent = overall?.usedPercent ?? totalPercentUsed {
                pools.append(CursorUsagePool(kind: .included, window: window(percent)))
            }
        }

        onDemand = (try? individual?.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("onDemand")))
            .flatMap(Self.spending)
        let team = try? root.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("teamUsage"))
        teamOnDemand = (try? team?.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("onDemand")))
            .flatMap(Self.spending)
    }

    private static func spending(_ container: KeyedDecodingContainer<AnyCodingKey>) -> CursorSpending? {
        let used = container.lenientDouble("used")
        let limit = container.lenientDouble("limit")
        guard let isEnabled = container.lenient(Bool.self, "enabled") ?? (used != nil ? true : nil) else {
            return nil
        }
        return CursorSpending(isEnabled: isEnabled, used: used, limit: limit)
    }

    /// ISO 8601, with or without fractional seconds, or milliseconds since 1970.
    private static func date(_ container: KeyedDecodingContainer<AnyCodingKey>, _ key: String) -> Date? {
        if let string = container.lenient(String.self, key) {
            if let date = try? Date(string, strategy: .iso8601) { return date }
            if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            return Double(string).map { Date(timeIntervalSince1970: $0 / 1000) }
        }
        return container.lenientDouble(key).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}
