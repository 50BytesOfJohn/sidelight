import Foundation

/// The pieces of a Codex sessions widget, arranged in its builder.
public enum CodexSessionsBlock: String, WidgetBlockKind, CaseIterable, Identifiable {
    /// The most urgent session in detail: its plan, context, changes and last message.
    case spotlight
    /// Sessions most urgent first.
    case sessions
    /// The plan's usage limits, as Codex last reported them.
    case limits

    public static let fixedBlocks: [CodexSessionsBlock] = [.spotlight, .sessions, .limits]

    public var id: Self { self }

    public var isShownByDefault: Bool { self != .limits }
}

public struct CodexSpotlightOptions: Codable, Hashable, Sendable {
    /// The steps of the plan Codex keeps for the turn, when it made one.
    public var showsPlan = true
    /// Context left, files changed, model and agents working.
    public var showsDetails = true
    /// The start of the agent's latest message, once a turn is over.
    public var showsLastMessage = true

    public init(showsPlan: Bool = true, showsDetails: Bool = true, showsLastMessage: Bool = true) {
        self.showsPlan = showsPlan
        self.showsDetails = showsDetails
        self.showsLastMessage = showsLastMessage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsPlan = try container.decodeIfPresent(Bool.self, forKey: .showsPlan) ?? true
        showsDetails = try container.decodeIfPresent(Bool.self, forKey: .showsDetails) ?? true
        showsLastMessage = try container.decodeIfPresent(Bool.self, forKey: .showsLastMessage) ?? true
    }
}

public struct CodexSessionListOptions: Codable, Hashable, Sendable {
    /// What the builder offers for ``maximumRows``.
    public static let rowCountRange = 1...10

    /// Rows in the regular size; compact shows fewer.
    public var maximumRows = 5
    /// The git branch next to the project.
    public var showsBranch = true

    public init(maximumRows: Int = 5, showsBranch: Bool = true) {
        self.maximumRows = maximumRows
        self.showsBranch = showsBranch
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CodexSessionListOptions()
        maximumRows = min(
            max(
                try container.decodeIfPresent(Int.self, forKey: .maximumRows) ?? defaults.maximumRows,
                Self.rowCountRange.lowerBound),
            Self.rowCountRange.upperBound)
        showsBranch = try container.decodeIfPresent(Bool.self, forKey: .showsBranch) ?? defaults.showsBranch
    }
}

public struct CodexSessionLimitsOptions: Codable, Hashable, Sendable {
    public var reading = UsageReading.remaining
    /// The longer of two limits, normally the week.
    public var showsWeeklyLimit = true

    public init(reading: UsageReading = .remaining, showsWeeklyLimit: Bool = true) {
        self.reading = reading
        self.showsWeeklyLimit = showsWeeklyLimit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reading = (try? container.decodeIfPresent(UsageReading.self, forKey: .reading)) ?? .remaining
        showsWeeklyLimit = try container.decodeIfPresent(Bool.self, forKey: .showsWeeklyLimit) ?? true
    }
}

/// Each block's options, side by side, so hiding a block and showing it again loses nothing.
public struct CodexSessionsBlockOptions: Codable, Hashable, Sendable {
    public var spotlight = CodexSpotlightOptions()
    public var sessions = CodexSessionListOptions()
    public var limits = CodexSessionLimitsOptions()

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        spotlight = try container.decodeIfPresent(CodexSpotlightOptions.self, forKey: .spotlight) ?? .init()
        sessions = try container.decodeIfPresent(CodexSessionListOptions.self, forKey: .sessions) ?? .init()
        limits = try container.decodeIfPresent(CodexSessionLimitsOptions.self, forKey: .limits) ?? .init()
    }
}

/// A Codex sessions widget: which sessions it lists, and which blocks it shows with what options.
public struct CodexSessionsSettings: Codable, Hashable, Sendable {
    /// What the settings offer for ``recentHours``.
    public static let recentHourChoices = [1, 4, 12, 24]

    /// Finished, idle and closed sessions stay listed this long. Sessions that are working or need the user always
    /// show.
    public var recentHours = 4
    /// Sessions run by `codex exec`, from scripts and CI. Codex's own session list leaves them out too.
    public var includesExec = false
    public var blocks = BlockLayout<CodexSessionsBlock>()
    public var blockOptions = CodexSessionsBlockOptions()

    public init(recentHours: Int = 4, includesExec: Bool = false, blocks: BlockLayout<CodexSessionsBlock> = .init()) {
        self.recentHours = recentHours
        self.includesExec = includesExec
        self.blocks = blocks
    }

    /// Missing options take their defaults, and unknown blocks don't fail the whole configuration.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CodexSessionsSettings()
        recentHours = max(1, try container.decodeIfPresent(Int.self, forKey: .recentHours) ?? defaults.recentHours)
        includesExec = try container.decodeIfPresent(Bool.self, forKey: .includesExec) ?? defaults.includesExec
        blocks =
            (try? container.decodeIfPresent(BlockLayout<CodexSessionsBlock>.self, forKey: .blocks)) ?? defaults.blocks
        blockOptions =
            try container.decodeIfPresent(CodexSessionsBlockOptions.self, forKey: .blockOptions)
            ?? defaults.blockOptions
    }

    public var recentWindow: TimeInterval { TimeInterval(recentHours) * 60 * 60 }
}
