import Foundation

/// A coding agent whose plan usage the AI Usage widget shows. Each reads the same service as its own widget.
public enum AIUsageProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claudeCode, cursor

    public var id: Self { self }

    /// Where its accounts are kept.
    public var accountProvider: AccountProvider {
        switch self {
        case .codex: .codex
        case .claudeCode: .claudeCode
        case .cursor: .cursor
        }
    }

    /// Whether a block can show another account than the default one. Claude Code keeps more than one signed in;
    /// Codex and Cursor read the one their app is signed in to.
    public var hasAccounts: Bool { accountProvider.canAddAccounts }
}

/// One block of an AI Usage widget: one agent's limits, for one of its accounts. A widget can have any number, the
/// same agent's more than once, each with its options in ``AIUsageSettings/options(_:)`` under its ID.
///
/// Stored as `<agent>:<UUID>`, like `claudeCode:6F1C2D3E-…`.
public struct AIUsageBlock: WidgetBlockKind, Identifiable {
    public var provider: AIUsageProvider
    public var id: UUID

    public init(_ provider: AIUsageProvider, id: UUID = UUID()) {
        self.provider = provider
        self.id = id
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let provider = AIUsageProvider(rawValue: parts[0]),
            let id = UUID(uuidString: parts[1])
        else { return nil }
        self.init(provider, id: id)
    }

    public var rawValue: String { "\(provider.rawValue):\(id.uuidString)" }

    /// None: every block is added, and can be removed.
    public static let fixedBlocks: [AIUsageBlock] = []

    public var isShownByDefault: Bool { true }

    /// Each agent's block in the presets. Their IDs are fixed, so choosing a preset again brings back the block as it
    /// was left, rather than adding another.
    public static let codex = AIUsageBlock(.codex, id: UUID(uuidString: "6F1C2D3E-7A8B-4C9D-8E0F-A1B2C3D40001")!)
    public static let claudeCode = AIUsageBlock(
        .claudeCode, id: UUID(uuidString: "6F1C2D3E-7A8B-4C9D-8E0F-A1B2C3D40002")!)
    public static let cursor = AIUsageBlock(.cursor, id: UUID(uuidString: "6F1C2D3E-7A8B-4C9D-8E0F-A1B2C3D40003")!)
}

/// What one block shows besides its agent.
public struct AIUsageBlockOptions: Codable, Hashable, Sendable {
    /// Shown in place of the agent's name, to tell blocks apart; `nil` for the agent's name.
    public var label: String?
    /// The account it shows, for an agent with accounts (``AIUsageProvider/hasAccounts``); `nil` for the default.
    public var account: AccountID?

    public init(label: String? = nil, account: AccountID? = nil) {
        self.label = label
        self.account = account
    }

    /// An empty label is no label, and an account reference that can't be read is the default account.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label).flatMap { $0.isEmpty ? nil : $0 }
        account = container.decodeLeniently(.account, or: nil)
    }

    private enum CodingKeys: String, CodingKey {
        case label
        case account = "accountID"
    }
}

/// Ready-made layouts for an AI Usage widget, made of the agents' preset blocks.
public enum AIUsagePreset: String, CaseIterable, Identifiable, Sendable {
    /// Codex, Claude Code and Cursor.
    case everyAgent
    /// Codex and Claude Code, which need nothing connected.
    case codexAndClaude

    public var id: Self { self }

    /// The blocks it shows, in order.
    public var blocks: [AIUsageBlock] {
        switch self {
        case .everyAgent: [.codex, .claudeCode, .cursor]
        case .codexAndClaude: [.codex, .claudeCode]
        }
    }
}

/// The AI Usage widget: agents' limits side by side, built from blocks, one per agent and account. How limits read
/// and when they're fetched belong to the widget, shared by its blocks. Fetching from Anthropic or Cursor is its own
/// opt-in, separate from the Claude Code and Cursor widgets', so it works without them.
public struct AIUsageSettings: Codable, Hashable, Sendable {
    public var blocks = BlockLayout<AIUsageBlock>(shown: AIUsagePreset.everyAgent.blocks)
    /// Each block's options, by its ID; a block without any has the defaults.
    public private(set) var blockOptions: [String: AIUsageBlockOptions] = [:]
    /// Defaults to what's used, like Claude Code and Cursor; Codex's own widget defaults to what's left.
    public var reading = UsageReading.used
    /// Each agent's other limits next to the one closest to running out, in the regular and compact layouts.
    public var showsOtherLimits = true
    /// Ask Anthropic for every shown Claude account's usage every ``claudeRefreshMinutes``; see
    /// ``ClaudeCodeSettings/refreshesFromAnthropic``.
    public var refreshesClaudeFromAnthropic = false
    public var claudeRefreshMinutes = 5
    /// Ask Cursor for its usage every ``cursorRefreshMinutes``; see ``CursorSettings/refreshesFromCursor``. Cursor
    /// keeps no usage on this Mac, so its blocks ask to be connected until this is on.
    public var refreshesCursor = false
    public var cursorRefreshMinutes = 15

    /// `blocks` shown in that order, each with its `options`.
    public init(
        blocks: [AIUsageBlock] = AIUsagePreset.everyAgent.blocks, options: [AIUsageBlock: AIUsageBlockOptions] = [:],
        reading: UsageReading = .used, showsOtherLimits: Bool = true, refreshesClaudeFromAnthropic: Bool = false,
        claudeRefreshMinutes: Int = 5, refreshesCursor: Bool = false, cursorRefreshMinutes: Int = 15
    ) {
        self.blocks = BlockLayout(shown: blocks)
        self.reading = reading
        self.showsOtherLimits = showsOtherLimits
        self.refreshesClaudeFromAnthropic = refreshesClaudeFromAnthropic
        self.claudeRefreshMinutes = claudeRefreshMinutes
        self.refreshesCursor = refreshesCursor
        self.cursorRefreshMinutes = cursorRefreshMinutes
        for (block, options) in options { setOptions(options, for: block) }
    }

    /// Missing options take their defaults, unknown readings and blocks don't fail the whole configuration,
    /// hand-edited intervals are moved into range, and only the blocks the layout has keep their options.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AIUsageSettings()
        blocks = container.decodeLeniently(.blocks, or: defaults.blocks)
        let options = container.decodeLeniently(.blockOptions, or: [String: AIUsageBlockOptions]())
        blockOptions = options.filter { key, _ in blocks.entries.contains { $0.block.id.uuidString == key } }
        reading = container.decodeLeniently(.reading, or: defaults.reading)
        showsOtherLimits = try container.decode(.showsOtherLimits, or: defaults.showsOtherLimits)
        refreshesClaudeFromAnthropic =
            try container.decode(.refreshesClaudeFromAnthropic, or: defaults.refreshesClaudeFromAnthropic)
        claudeRefreshMinutes = try container.decode(.claudeRefreshMinutes, or: defaults.claudeRefreshMinutes).clamped(
            to: UsageRefresh.minuteRange)
        refreshesCursor = try container.decode(.refreshesCursor, or: defaults.refreshesCursor)
        cursorRefreshMinutes = try container.decode(.cursorRefreshMinutes, or: defaults.cursorRefreshMinutes).clamped(
            to: UsageRefresh.minuteRange)
    }

    // MARK: Blocks

    public func options(_ block: AIUsageBlock) -> AIUsageBlockOptions {
        blockOptions[block.id.uuidString] ?? AIUsageBlockOptions()
    }

    public mutating func setOptions(_ options: AIUsageBlockOptions, for block: AIUsageBlock) {
        guard blocks.contains(block) else { return }
        blockOptions[block.id.uuidString] = options
    }

    /// Adds a block for `provider`, shown at the end, and returns it.
    @discardableResult
    public mutating func addBlock(_ provider: AIUsageProvider, options: AIUsageBlockOptions = .init()) -> AIUsageBlock {
        let block = AIUsageBlock(provider)
        blocks.add(block)
        blockOptions[block.id.uuidString] = options
        return block
    }

    /// Removes a block with its options.
    public mutating func removeBlock(_ block: AIUsageBlock) {
        blocks.remove(block)
        blockOptions[block.id.uuidString] = nil
    }

    /// Shows `preset`'s blocks and hides the rest. Its blocks keep whatever options they were left with.
    public mutating func apply(_ preset: AIUsagePreset) {
        blocks.showOnly(preset.blocks)
    }

    /// The preset the shown blocks match, if any.
    public var preset: AIUsagePreset? {
        AIUsagePreset.allCases.first { blocks.shownBlocks == $0.blocks }
    }

    /// The agents with a block shown.
    public var shownProviders: Set<AIUsageProvider> {
        Set(blocks.shownBlocks.map(\.provider))
    }

    // MARK: Fetching

    /// The Anthropic refresh interval in minutes, when this widget shows a Claude block and opted in.
    public var claudeRefreshMinutesIfOptedIn: Int? {
        shownProviders.contains(.claudeCode) && refreshesClaudeFromAnthropic ? claudeRefreshMinutes : nil
    }

    /// The Cursor refresh interval in minutes, when this widget shows a Cursor block and opted in.
    public var cursorRefreshMinutesIfOptedIn: Int? {
        shownProviders.contains(.cursor) && refreshesCursor ? cursorRefreshMinutes : nil
    }

    // MARK: Accounts

    /// The account each block of an agent with accounts names, `nil` for its default: only the shown blocks', or
    /// every block's, hidden ones included.
    public func accountReferences(shownOnly: Bool) -> [(provider: AccountProvider, account: AccountID?)] {
        let entries = shownOnly ? blocks.entries.filter(\.isShown) : blocks.entries
        return entries.map(\.block).filter(\.provider.hasAccounts).map { block in
            (block.provider.accountProvider, options(block).account)
        }
    }

    /// Every block naming `id` shows its agent's default account instead; returns whether one did.
    public mutating func forgetAccount(_ id: AccountID) -> Bool {
        let named = blocks.entries.map(\.block).filter { options($0).account == id }
        for block in named {
            var options = options(block)
            options.account = nil
            setOptions(options, for: block)
        }
        return !named.isEmpty
    }
}
