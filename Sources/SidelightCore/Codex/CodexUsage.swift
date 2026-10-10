import Foundation

/// Rate limits as reported by `codex app-server` (camelCase) or a rollout file (snake_case).
public struct CodexRateLimits: Equatable, Sendable {
    /// The shorter window: 5 hours on paid plans. Free plans may have only a weekly one here.
    public var primary: RateLimitWindow?
    /// The longer window, usually the week.
    public var secondary: RateLimitWindow?
    public var planType: String?
    /// Purchased Codex credits, which keep Codex going past the plan's limits.
    public var credits: CodexCredits?
    /// Why Codex stopped ordinary usage, such as `rate_limit_reached` or `workspace_member_credits_depleted`.
    public var reachedType: String?

    public init(
        primary: RateLimitWindow? = nil,
        secondary: RateLimitWindow? = nil,
        planType: String? = nil,
        credits: CodexCredits? = nil,
        reachedType: String? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.credits = credits
        self.reachedType = reachedType
    }

    /// These limits with a sparse `account/rateLimits/updated` notification merged in: Codex leaves out what it
    /// doesn't know in those, which doesn't clear what an earlier read said.
    public func merging(_ update: CodexRateLimits) -> CodexRateLimits {
        CodexRateLimits(
            primary: update.primary ?? primary,
            secondary: update.secondary ?? secondary,
            planType: update.planType ?? planType,
            credits: update.credits ?? credits,
            reachedType: update.reachedType ?? reachedType
        )
    }

    /// The limits to show, shortest window first. `includesLonger: false` leaves out the longer of two windows
    /// (the weekly one); a single window always stays, whatever its length.
    public func limits(includesLonger: Bool = true) -> [CodexLimit] {
        var limits = [
            primary.map { CodexLimit(role: .primary, window: $0) },
            secondary.map { CodexLimit(role: .secondary, window: $0) },
        ]
        .compactMap(\.self)
        // Codex sends the shorter window as the primary one, but don't rely on it for naming and order.
        limits.sort {
            ($0.window.durationMinutes ?? 0, $0.role.rawValue) < ($1.window.durationMinutes ?? 0, $1.role.rawValue)
        }
        if !includesLonger, limits.count > 1 { limits.removeLast() }
        return limits
    }
}

/// Purchased Codex credits, from a rate-limit snapshot.
public struct CodexCredits: Equatable, Sendable {
    public var hasCredits: Bool
    public var isUnlimited: Bool
    /// The balance as Codex sends it: a decimal number in a string.
    public var balance: String?

    public init(hasCredits: Bool, isUnlimited: Bool = false, balance: String? = nil) {
        self.hasCredits = hasCredits
        self.isUnlimited = isUnlimited
        self.balance = balance
    }
}

/// An `account/rateLimits/read` response.
public struct CodexRateLimitsReading: Equatable, Sendable {
    public var rateLimits: CodexRateLimits
    /// Rate-limit reset credits the account can spend (in Codex itself) to start a window over.
    public var resetCredits: Int?
    /// Whether the account may use its plan's included usage right now. `nil` when Codex doesn't say, which
    /// doesn't mean it may: don't guess it from percentages or reset times.
    public var ordinaryUsageAllowed: Bool?

    public init(rateLimits: CodexRateLimits, resetCredits: Int? = nil, ordinaryUsageAllowed: Bool? = nil) {
        self.rateLimits = rateLimits
        self.resetCredits = resetCredits
        self.ordinaryUsageAllowed = ordinaryUsageAllowed
    }
}

/// Who Codex is signed in as, from `account/read`. Plan limits only exist for ChatGPT sign-ins.
public enum CodexAccount: Equatable, Sendable {
    case chatGPT(plan: String?)
    case apiKey
    /// Another provider, such as Amazon Bedrock, or one that needs no OpenAI sign-in.
    case otherProvider
    case signedOut

    public var hasPlanLimits: Bool {
        if case .chatGPT = self { true } else { false }
    }
}

/// One of the account's limits, named after how long its window is rather than which slot it came in.
public struct CodexLimit: Equatable, Sendable, Identifiable {
    public enum Role: Int, Sendable {
        case primary, secondary
    }

    public var role: Role
    public var window: RateLimitWindow

    public var id: Role { role }

    public init(role: Role, window: RateLimitWindow) {
        self.role = role
        self.window = window
    }

    /// `5-hour`, `Weekly`, `2-day`.
    public var title: String {
        guard let minutes = window.durationMinutes, minutes > 0 else {
            return role == .primary ? "Usage limit" : "Longer limit"
        }
        if minutes == 7 * 24 * 60 { return "Weekly" }
        if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }

    /// `5h`, `wk`, `2d`, for the smallest layouts; empty when the window's length is unknown.
    public var shortTitle: String {
        guard let minutes = window.durationMinutes, minutes > 0 else { return "" }
        if minutes == 7 * 24 * 60 { return "wk" }
        if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    /// Meter segments, one per natural unit of the window: an hour of a 5-hour window, a day of a week. One plain
    /// segment when the length is unknown or has no natural unit.
    public var segments: Int {
        guard let minutes = window.durationMinutes, minutes > 0 else { return 1 }
        if minutes % (24 * 60) == 0, (2...14).contains(minutes / (24 * 60)) { return minutes / (24 * 60) }
        if minutes % 60 == 0, (2...12).contains(minutes / 60) { return minutes / 60 }
        return 1
    }

    /// Whether the window's reset has passed since Codex reported it, so its usage is no longer known.
    public func hasReset(at now: Date) -> Bool {
        window.resetsAt.map { $0 <= now } ?? false
    }

    public var isUsedUp: Bool { window.usedPercent >= 100 }

    /// Of several limits, the one that runs out first: the most used among those still current at `now`.
    public static func tightest(_ limits: [CodexLimit], at now: Date) -> CodexLimit? {
        limits.filter { !$0.hasReset(at: now) }.max { $0.window.usedPercent < $1.window.usedPercent } ?? limits.first
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
    /// A window without its used percentage fails to decode, so a malformed one reads as missing rather than as
    /// unused.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        guard let usedPercent = container.lenientDouble("usedPercent", "used_percent") else {
            throw DecodingError.keyNotFound(
                AnyCodingKey("usedPercent"),
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "No used percentage")
            )
        }
        self.init(
            usedPercent: usedPercent,
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
            planType: container.lenient(String.self, "planType", "plan_type"),
            credits: container.lenient(CodexCredits.self, "credits"),
            reachedType: container.lenient(String.self, "rateLimitReachedType", "rate_limit_reached_type")
        )
    }
}

extension CodexCredits: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        guard let hasCredits = container.lenient(Bool.self, "hasCredits", "has_credits") else {
            throw DecodingError.keyNotFound(
                AnyCodingKey("hasCredits"),
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "No credits flag")
            )
        }
        self.init(
            hasCredits: hasCredits,
            isUnlimited: container.lenient(Bool.self, "unlimited") ?? false,
            balance: container.lenient(String.self, "balance")
        )
    }
}
