import Foundation

/// Claude plan limits at one moment, as Claude Code last saw them.
public struct ClaudeCodeUsage: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Claude Code's status line input, saved by Sidelight's bridge script after each response.
        case statusLine
        /// Claude Code's cache of what `/usage` last fetched, in `~/.claude.json`.
        case usageCache
        /// Fetched from Anthropic by Sidelight itself, with Claude Code's sign-in.
        case anthropic
    }

    public static let sessionMinutes = 5 * 60
    public static let weekMinutes = 7 * 24 * 60

    /// The rolling 5-hour session limit. It starts with the first request after the previous one ran out.
    public var session: RateLimitWindow?
    /// The weekly limit, which resets at the same time every week.
    public var weekly: RateLimitWindow?
    public var capturedAt: Date
    public var source: Source

    public init(session: RateLimitWindow?, weekly: RateLimitWindow?, capturedAt: Date, source: Source) {
        self.session = session
        self.weekly = weekly
        self.capturedAt = capturedAt
        self.source = source
    }

    /// The limits as they stand at `now`: windows that reset since the capture start again from zero.
    public func current(at now: Date) -> ClaudeCodeUsage {
        var usage = self
        usage.session = session?.current(at: now, resetsOnSchedule: false)
        usage.weekly = weekly?.current(at: now, resetsOnSchedule: true)
        return usage
    }

    /// Of two captures, the one taken last.
    public static func newest(_ first: ClaudeCodeUsage?, _ second: ClaudeCodeUsage?) -> ClaudeCodeUsage? {
        guard let first, let second else { return first ?? second }
        return second.capturedAt > first.capturedAt ? second : first
    }
}

// MARK: - Status line

extension ClaudeCodeUsage {
    /// Reads Claude Code's status line input (https://code.claude.com/docs/en/statusline). `nil` when it has no
    /// rate limits: they come only for Pro and Max plans, and only after a session's first response.
    public init?(statusLine data: Data, capturedAt: Date) {
        guard let input = try? JSONDecoder().decode(StatusLineInput.self, from: data),
            input.session != nil || input.weekly != nil
        else { return nil }
        self.init(session: input.session, weekly: input.weekly, capturedAt: capturedAt, source: .statusLine)
    }
}

private struct StatusLineInput: Decodable {
    var session: RateLimitWindow?
    var weekly: RateLimitWindow?

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: AnyCodingKey.self)
        let limits = try? root.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("rate_limits"))
        session = Self.window(limits, "five_hour", minutes: ClaudeCodeUsage.sessionMinutes)
        weekly = Self.window(limits, "seven_day", minutes: ClaudeCodeUsage.weekMinutes)
    }

    private static func window(
        _ limits: KeyedDecodingContainer<AnyCodingKey>?, _ key: String, minutes: Int
    ) -> RateLimitWindow? {
        guard let window = try? limits?.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey(key)),
            let percent = window.lenientDouble("used_percentage")
        else { return nil }
        return RateLimitWindow(
            usedPercent: percent,
            resetsAt: window.lenientDouble("resets_at").map(Date.init(timeIntervalSince1970:)),
            durationMinutes: minutes
        )
    }
}

// MARK: - ~/.claude.json

/// What Sidelight reads from Claude Code's own state file, `~/.claude.json`. Its schema is internal to Claude
/// Code, so every part is optional.
public struct ClaudeCodeAccountState: Equatable, Sendable {
    /// What `/usage` last fetched, unless it belongs to another account than the one signed in now.
    public var usage: ClaudeCodeUsage?
    /// `Pro`, `Max`, `Team`…
    public var plan: String?

    public init(usage: ClaudeCodeUsage? = nil, plan: String? = nil) {
        self.usage = usage
        self.plan = plan
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(AccountStateFile.self, from: data).state
    }

    /// `claude_max` → `Max`.
    static func planName(organizationType: String) -> String? {
        guard organizationType.hasPrefix("claude_") else { return nil }
        let words = organizationType.dropFirst("claude_".count).split(separator: "_")
        return words.isEmpty ? nil : words.map(\.capitalized).joined(separator: " ")
    }
}

private struct AccountStateFile: Decodable {
    var state = ClaudeCodeAccountState()

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: AnyCodingKey.self)
        let account = try? root.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("oauthAccount"))
        state.plan = account?.lenient(String.self, "organizationType").flatMap(ClaudeCodeAccountState.planName)

        guard
            let cache = try? root.nestedContainer(
                keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("cachedUsageUtilization")),
            let fetchedAt = cache.lenientDouble("fetchedAtMs"),
            let utilization = cache.lenient(UsageUtilization.self, "utilization")
        else { return }
        let cacheAccount = cache.lenient(String.self, "accountUuid")
        let signedInAccount = account?.lenient(String.self, "accountUuid")
        if let cacheAccount, let signedInAccount, cacheAccount != signedInAccount { return }
        state.usage = utilization.usage(capturedAt: Date(timeIntervalSince1970: fetchedAt / 1000), source: .usageCache)
    }
}

// MARK: - Anthropic's usage endpoint

extension ClaudeCodeUsage {
    /// Reads a response of ``ClaudeCodeUsageAPI``. `nil` when it has no limits.
    public init?(usageResponse data: Data, fetchedAt: Date) {
        guard let utilization = try? JSONDecoder().decode(UsageUtilization.self, from: data),
            let usage = utilization.usage(capturedAt: fetchedAt, source: .anthropic)
        else { return nil }
        self = usage
    }
}

/// Usage as Anthropic's usage endpoint reports it, which is also what Claude Code caches: a window per limit,
/// with `utilization` in percent and `resets_at` as an ISO 8601 date.
private struct UsageUtilization: Decodable {
    var session: RateLimitWindow?
    var weekly: RateLimitWindow?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        session = Self.window(container, "five_hour", minutes: ClaudeCodeUsage.sessionMinutes)
        weekly = Self.window(container, "seven_day", minutes: ClaudeCodeUsage.weekMinutes)
    }

    func usage(capturedAt: Date, source: ClaudeCodeUsage.Source) -> ClaudeCodeUsage? {
        guard session != nil || weekly != nil else { return nil }
        return ClaudeCodeUsage(session: session, weekly: weekly, capturedAt: capturedAt, source: source)
    }

    private static func window(
        _ container: KeyedDecodingContainer<AnyCodingKey>, _ key: String, minutes: Int
    ) -> RateLimitWindow? {
        guard let window = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey(key)),
            let percent = window.lenientDouble("utilization")
        else { return nil }
        return RateLimitWindow(
            usedPercent: percent,
            resetsAt: window.lenient(String.self, "resets_at").flatMap { try? Date($0, strategy: .iso8601) },
            durationMinutes: minutes
        )
    }
}
