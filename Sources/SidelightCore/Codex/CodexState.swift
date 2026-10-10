import Foundation

/// Everything known about Codex's limits and usage, as one value, so a view can be drawn for any state.
public struct CodexState: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case off
        case starting
        /// `codex app-server`, asked every ``CodexState/refreshInterval``.
        case appServer
        /// The newest session rollout file, re-read whenever Codex writes to it.
        case rolloutFile
        /// Neither answers: Codex isn't installed or hasn't been used on this Mac.
        case unavailable
    }

    /// How often the app-server is asked.
    public static let refreshInterval: Duration = .seconds(60)

    public var source = Source.off
    /// Who Codex is signed in as; `nil` until the app-server says (it never does without one).
    public var account: CodexAccount?
    public var rateLimits: CodexRateLimits?
    /// When ``rateLimits`` were read or logged.
    public var limitsCapturedAt: Date?
    public var ordinaryUsageAllowed: Bool?
    public var resetCredits: Int?
    public var usage: CodexUsage?
    /// Tokens of the latest session; only known from rollout files.
    public var sessionTokens: Int64?
    /// Why the app-server's last rate-limit read failed; cleared by the next good one.
    public var problem: String?

    public init(
        source: Source = .off, account: CodexAccount? = nil, rateLimits: CodexRateLimits? = nil,
        limitsCapturedAt: Date? = nil, ordinaryUsageAllowed: Bool? = nil, resetCredits: Int? = nil,
        usage: CodexUsage? = nil, sessionTokens: Int64? = nil, problem: String? = nil
    ) {
        self.source = source
        self.account = account
        self.rateLimits = rateLimits
        self.limitsCapturedAt = limitsCapturedAt
        self.ordinaryUsageAllowed = ordinaryUsageAllowed
        self.resetCredits = resetCredits
        self.usage = usage
        self.sessionTokens = sessionTokens
        self.problem = problem
    }

    public var plan: String? {
        if let plan = rateLimits?.planType { return plan }
        if case .chatGPT(let plan) = account { return plan }
        return nil
    }

    /// Whether the limits are current: read from the app-server within the last few refreshes, without an error
    /// since. Forecasts only make sense then.
    public func isLive(at now: Date) -> Bool {
        guard source == .appServer, problem == nil, let limitsCapturedAt else { return false }
        return now.timeIntervalSince(limitsCapturedAt) < 3 * Double(Self.refreshInterval.components.seconds)
    }

    /// Codex has stopped ordinary usage, whatever the percentages say. `nil` from Codex isn't read as allowed or not.
    public var isBlocked: Bool {
        ordinaryUsageAllowed == false || rateLimits?.reachedType != nil
    }

    /// Old numbers: not live, and either an error since or more than half an hour since Codex reported them.
    public func isStale(at now: Date) -> Bool {
        guard !isLive(at: now) else { return false }
        if problem != nil { return true }
        guard let limitsCapturedAt else { return true }
        return now.timeIntervalSince(limitsCapturedAt) > 30 * 60
    }
}
