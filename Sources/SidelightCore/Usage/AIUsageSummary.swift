import Foundation

/// One limit an agent is held to, as the AI Usage widget shows it: a rolling window such as Codex's or Claude's
/// 5-hour one, or one of Cursor's pools over the billing cycle.
public struct AIUsageLimit: Equatable, Sendable, Identifiable {
    public var id: String
    /// `5-hour`, `Weekly`, `API models`.
    public var title: String
    /// `5h`, `wk`, `API`.
    public var shortTitle: String
    public var window: RateLimitWindow
    /// Meter segments, one per natural unit: an hour of a 5-hour window, a day of a week, a week of a billing cycle.
    public var segments: Int
    /// A billing cycle, whose reset reads as a date, rather than a rolling window.
    public var isBillingCycle = false
    /// Claude's 5-hour session: it starts with the first message after the last one ran out, so without a reset
    /// time it hasn't started.
    public var startsWithNextMessage = false
    /// What the provider says this limit covers, for tooltips.
    public var explanation: String?

    public init(
        id: String, title: String, shortTitle: String, window: RateLimitWindow, segments: Int,
        isBillingCycle: Bool = false, startsWithNextMessage: Bool = false, explanation: String? = nil
    ) {
        self.id = id
        self.title = title
        self.shortTitle = shortTitle
        self.window = window
        self.segments = segments
        self.isBillingCycle = isBillingCycle
        self.startsWithNextMessage = startsWithNextMessage
        self.explanation = explanation
    }

    /// Whether the window's reset has passed since the numbers were read. Its new usage isn't known until the
    /// provider reports it, so it's neither shown as used up nor as fully available.
    public func hasReset(at now: Date) -> Bool {
        window.resetsAt.map { $0 <= now } ?? false
    }

    public var isUsedUp: Bool { window.usedPercent >= 100 }

    /// The share used or left, 0–100.
    public func percent(_ reading: UsageReading) -> Double {
        let used = min(max(window.usedPercent, 0), 100)
        return reading == .remaining ? 100 - used : used
    }
}

/// One agent's usage, reduced to what the AI Usage widget needs to draw it next to the others: its limits, which
/// one is closest to running out, how current the numbers are, and anything that stops it from showing numbers.
///
/// Built from each service's own state, with each provider's semantics kept: nothing is added up across agents or
/// windows, a reset that has passed is shown as unknown rather than as a full allowance, and nothing missing is
/// filled in.
public struct AIUsageSummary: Equatable, Sendable, Identifiable {
    /// Why there are no limits to draw, or `limits` when there are.
    public enum Status: Equatable, Sendable {
        case limits
        case loading(String)
        /// Something the user has to do: connect, sign in, install.
        case setup(title: String, detail: String)
        /// Nothing to measure: signed in without plan limits, or an unlimited plan.
        case noLimits(title: String, detail: String?)
        /// Reading failed, and nothing was read before.
        case failed(title: String, detail: String?)
    }

    public enum Freshness: Equatable, Sendable {
        /// Current enough to forecast from.
        case live
        /// Not just read, but nothing says it's wrong: the agent may simply not have run since.
        case aged
        /// Out of date: reading has failed since, or it's long overdue.
        case stale
    }

    public struct Notice: Equatable, Sendable {
        public enum Severity: Equatable, Sendable {
            case info, warning, critical
        }

        public var text: String
        public var severity: Severity

        public init(_ text: String, severity: Severity) {
            self.text = text
            self.severity = severity
        }
    }

    /// What needs attention about one limit.
    public enum Warning: Equatable, Sendable {
        case usedUp
        /// At this pace, it runs out at this time, well before it resets.
        case runsOut(Date)
    }

    public var provider: AIUsageProvider
    public var status: Status
    /// Shortest window first.
    public var limits: [AIUsageLimit]
    public var plan: String?
    /// When the numbers were read or logged.
    public var capturedAt: Date?
    public var freshness: Freshness
    /// Where the numbers come from, for tooltips: `codex app-server`, `Claude Code's status line`.
    public var source: String?
    /// What the numbers alone don't say: why usage stopped, or why they're old.
    public var notice: Notice?

    public var id: AIUsageProvider { provider }

    public init(
        provider: AIUsageProvider, status: Status, limits: [AIUsageLimit] = [], plan: String? = nil,
        capturedAt: Date? = nil, freshness: Freshness = .live, source: String? = nil, notice: Notice? = nil
    ) {
        self.provider = provider
        self.status = status
        self.limits = limits
        self.plan = plan
        self.capturedAt = capturedAt
        self.freshness = freshness
        self.source = source
        self.notice = notice
    }

    /// The limit that stops this agent first: the most used of those still current at `now`, the shorter window
    /// on a tie. When every one has reset, the first, shown as reset.
    public func lead(at now: Date) -> AIUsageLimit? {
        limits.filter { !$0.hasReset(at: now) }.max { $0.window.usedPercent < $1.window.usedPercent } ?? limits.first
    }

    /// Every limit but the lead, in order.
    public func others(at now: Date) -> [AIUsageLimit] {
        let lead = lead(at: now)
        return limits.filter { $0.id != lead?.id }
    }

    /// How far ahead of its reset, as a share of the window, a limit has to run out to be worth a warning: running
    /// out just before is within the noise of a forecast.
    public static let forecastMargin = 0.05

    /// A limit that's used up, or, while the numbers are live, runs out well before it resets.
    public func warning(for limit: AIUsageLimit, at now: Date) -> Warning? {
        guard !limit.hasReset(at: now) else { return nil }
        if limit.isUsedUp { return .usedUp }
        guard freshness == .live, case .runsOut(let date) = limit.window.pace(at: now),
            let resetsAt = limit.window.resetsAt, let duration = limit.window.duration,
            resetsAt.timeIntervalSince(date) > duration * Self.forecastMargin
        else { return nil }
        return .runsOut(date)
    }
}

// MARK: - Codex

extension AIUsageSummary {
    /// Codex's limits named by their length, with `/status`'s semantics: a reset that has passed is unknown until
    /// Codex reports again, and a stop Codex reports (`ordinaryUsageAllowed`, `rateLimitReachedType`) counts
    /// whatever the percentages say. `plan` is the plan as people know it.
    public static func codex(_ state: CodexState, plan: String?, now: Date) -> AIUsageSummary {
        var summary = AIUsageSummary(provider: .codex, status: .loading("Reading Codex usage…"), plan: plan)
        switch state.account {
        case .signedOut?:
            summary.status = .setup(title: "Not signed in", detail: "Run codex login to see your plan's limits.")
            return summary
        case .apiKey?:
            summary.status = .noLimits(
                title: "Signed in with an API key", detail: "Plan limits apply with a ChatGPT sign-in.")
            return summary
        case .otherProvider?:
            summary.status = .noLimits(title: "No ChatGPT plan limits", detail: "Codex uses another provider.")
            return summary
        case .chatGPT?, nil:
            break
        }

        summary.limits = (state.rateLimits?.limits() ?? []).map { limit in
            AIUsageLimit(
                id: "codex.\(limit.role)", title: limit.title,
                shortTitle: limit.shortTitle.isEmpty ? limit.title : limit.shortTitle, window: limit.window,
                segments: limit.segments)
        }
        summary.capturedAt = state.limitsCapturedAt
        summary.freshness = state.isLive(at: now) ? .live : state.isStale(at: now) ? .stale : .aged
        summary.source =
            switch state.source {
            case .appServer: "codex app-server"
            case .rolloutFile: "Codex's session logs"
            case .starting, .off, .unavailable: state.limitsCapturedAt == nil ? nil : "codex app-server, reconnecting"
            }

        if !summary.limits.isEmpty {
            summary.status = .limits
        } else if state.rateLimits != nil {
            summary.status = .noLimits(
                title: "No limits reported", detail: "Codex sent no usage windows for this plan.")
        } else if let problem = state.problem {
            summary.status = .failed(title: "Can't read Codex limits", detail: problem)
        } else if state.source == .unavailable {
            summary.status = .setup(
                title: "Codex not found", detail: "Install the Codex CLI and sign in, or use Codex once on this Mac.")
        }

        if let reason = codexBlockedReason(state, limits: summary.limits, now: now) {
            summary.notice = Notice(reason, severity: .critical)
        } else if summary.freshness == .stale, let problem = state.problem {
            summary.notice = Notice("codex app-server: \(problem)", severity: .warning)
        }
        return summary
    }

    /// Why Codex stopped, unless a used-up limit already says so.
    private static func codexBlockedReason(_ state: CodexState, limits: [AIUsageLimit], now: Date) -> String? {
        guard state.isBlocked else { return nil }
        let reachedType = state.rateLimits?.reachedType
        let isExplained = limits.contains { $0.isUsedUp && !$0.hasReset(at: now) }
        if isExplained, reachedType.map({ $0 == "rate_limit_reached" }) ?? true { return nil }
        return switch reachedType {
        case "workspace_owner_credits_depleted", "workspace_member_credits_depleted": "Workspace credits used up"
        case "workspace_owner_usage_limit_reached", "workspace_member_usage_limit_reached":
            "Workspace usage limit reached"
        default: "Usage limit reached"
        }
    }
}

// MARK: - Claude Code

extension AIUsageSummary {
    /// Within this long, Claude's numbers count as current. They come with Claude Code's responses (or `/usage`),
    /// so older ones mostly mean it hasn't been used since.
    public static let claudeCodeLiveAge: TimeInterval = 15 * 60

    /// Claude's 5-hour session and week, from whichever source is newest. Unlike the Claude Code widget, a window
    /// whose reset has passed shows as reset, awaiting new numbers, like every other agent here, rather than as
    /// unused: usage since may come from claude.ai or another device.
    ///
    /// - Parameters:
    ///   - hasLoaded: Claude Code's files have been read at least once.
    ///   - anthropicProblem: Why the last opted-in fetch from Anthropic failed.
    public static func claudeCode(
        usage: ClaudeCodeUsage?, plan: String?, hasLoaded: Bool, anthropicProblem: ClaudeCodeFetchProblem?, now: Date
    ) -> AIUsageSummary {
        var summary = AIUsageSummary(provider: .claudeCode, status: .loading("Reading Claude Code usage…"), plan: plan)
        guard let usage else {
            if let anthropicProblem {
                summary.status = .failed(title: "Can't fetch Claude usage", detail: anthropicProblem.message)
            } else if hasLoaded {
                summary.status = .setup(
                    title: "No Claude limits yet",
                    detail: "Connect Claude Code's status line in this widget's settings, or run /usage in it.")
            }
            return summary
        }

        summary.limits = [
            usage.session.map {
                AIUsageLimit(
                    id: "claudeCode.session", title: "5-hour", shortTitle: "5h", window: $0, segments: 5,
                    startsWithNextMessage: true, explanation: "The session: 5 hours from your first message.")
            },
            usage.weekly.map {
                AIUsageLimit(id: "claudeCode.weekly", title: "Weekly", shortTitle: "wk", window: $0, segments: 7)
            },
        ]
        .compactMap(\.self)
        summary.status = summary.limits.isEmpty ? .noLimits(title: "No limits reported", detail: nil) : .limits
        summary.capturedAt = usage.capturedAt
        let age = now.timeIntervalSince(usage.capturedAt)
        summary.freshness = age <= claudeCodeLiveAge ? .live : anthropicProblem != nil ? .stale : .aged
        summary.source =
            switch usage.source {
            case .statusLine: "Claude Code's status line"
            case .usageCache: "Claude Code's /usage"
            case .anthropic: "Anthropic, with Claude Code's sign-in"
            }
        if summary.freshness == .stale, let anthropicProblem {
            summary.notice = Notice(anthropicProblem.message, severity: .warning)
        }
        return summary
    }
}

// MARK: - Cursor

extension AIUsageSummary {
    /// Cursor's included-usage pools over the billing cycle, for the whole account: the editor, the CLI and cloud
    /// agents all draw from them. Once the cycle has ended, the pools show as reset until the next fetch, since the
    /// next cycle's dates aren't known yet.
    ///
    /// - Parameters:
    ///   - isConnected: This widget opted in to fetching from Cursor. Without it, it shows nothing Cursor sent.
    ///   - isStale: The service's own judgement: a fetch failed since, or it's long overdue.
    public static func cursor(
        isConnected: Bool, usage: CursorUsage?, problem: CursorFetchProblem?, isStale: Bool, now: Date
    ) -> AIUsageSummary {
        var summary = AIUsageSummary(provider: .cursor, status: .loading("Fetching Cursor usage…"))
        guard isConnected else {
            summary.status = .setup(
                title: "Not connected", detail: "Turn on Fetch usage from Cursor in this widget's settings.")
            return summary
        }
        guard let usage else {
            if let problem {
                summary.status =
                    problem.needsSignIn
                    ? .setup(title: problem.title, detail: problem.advice)
                    : .failed(title: problem.title, detail: problem.advice)
            }
            return summary
        }

        summary.plan = usage.planName
        summary.capturedAt = usage.fetchedAt
        summary.freshness = isStale ? .stale : .live
        summary.source = "cursor.com"
        summary.limits = usage.pools.map { pool in
            let weeks = pool.window.duration.map { Int(($0 / (7 * 86_400)).rounded()) } ?? 4
            return AIUsageLimit(
                id: "cursor.\(pool.kind.rawValue)", title: pool.kind.title,
                shortTitle: cursorShortTitle(pool.kind), window: pool.window, segments: min(max(weeks, 1), 6),
                isBillingCycle: true,
                explanation: [pool.kind.explanation, pool.message].compactMap(\.self).joined(separator: "\n"))
        }
        if summary.limits.isEmpty {
            summary.status =
                usage.isUnlimited
                ? .noLimits(title: "Unlimited plan", detail: nil) : .noLimits(title: "No usage reported", detail: nil)
        } else {
            summary.status = .limits
        }

        if isStale, let problem {
            summary.notice = Notice("\(problem.title). \(problem.advice)", severity: .warning)
        } else if usage.onDemand?.isEnabled == true,
            summary.limits.contains(where: { $0.isUsedUp && !$0.hasReset(at: now) })
        {
            summary.notice = Notice("On-demand usage from here", severity: .info)
        }
        return summary
    }

    /// The pool's name next to "Cursor": `Auto` for Cursor's own models (Cursor reports it as `autoPercentUsed`).
    private static func cursorShortTitle(_ kind: CursorUsagePool.Kind) -> String {
        switch kind {
        case .cursorModels: "Auto"
        case .otherModels: "API"
        case .included: "Plan"
        }
    }
}
