import Foundation

// MARK: - Balance

/// Whose spending a Balance block's chart shows: the whole account, or one of its API keys.
public enum OpenRouterChartScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case account
    case key

    public var id: Self { self }
}

/// The spending chart under the balance: one bar per completed UTC day.
public struct OpenRouterSpendChartSettings: Codable, Hashable, Sendable {
    /// What the settings offer for ``days``.
    public static let dayChoices = [7, 14, 30]
    /// From the fewest days offered to the 30 completed UTC days OpenRouter reports. Hand-edited numbers are moved
    /// into it.
    public static let dayRange = 7...30

    public var isShown = true
    public var days = 7
    public var scope = OpenRouterChartScope.account
    /// The chosen key's hash, kept while the chart shows the account so choosing the key again restores it.
    public var keyHash: String?
    /// The key's name when it was chosen, to show while OpenRouter can't be asked or no longer has it.
    public var keyName: String?

    public init(
        isShown: Bool = true, days: Int = 7, scope: OpenRouterChartScope = .account, keyHash: String? = nil,
        keyName: String? = nil
    ) {
        self.isShown = isShown
        self.days = days
        self.scope = scope
        self.keyHash = keyHash
        self.keyName = keyName
    }

    /// Missing options take their defaults, an unknown scope charts the account, and a hand-edited number of days
    /// is moved into the range OpenRouter reports.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = OpenRouterSpendChartSettings()
        isShown = try container.decode(.isShown, or: defaults.isShown)
        days = try container.decode(.days, or: defaults.days).clamped(to: Self.dayRange)
        scope = container.decodeLeniently(.scope, or: defaults.scope)
        keyHash = try container.decodeIfPresent(String.self, forKey: .keyHash).flatMap { $0.isEmpty ? nil : $0 }
        keyName = try container.decodeIfPresent(String.self, forKey: .keyName)
    }

    /// Whose spending to fetch; `nil` while the chart is off, or set to a key without one chosen yet.
    public var spendScope: OpenRouterSpendScope? {
        guard isShown else { return nil }
        switch scope {
        case .account: return .account
        case .key: return keyHash.map(OpenRouterSpendScope.key)
        }
    }
}

/// What a Balance block shows: an account's balance, and optionally what it spent day by day.
public struct OpenRouterBalanceOptions: Codable, Hashable, Sendable {
    /// Shown above the balance, to tell accounts apart; `nil` for the default label.
    public var title: String?
    /// The OpenRouter account it reads; `nil` for the default account.
    public var account: AccountID?
    public var chart = OpenRouterSpendChartSettings()

    public init(title: String? = nil, account: AccountID? = nil, chart: OpenRouterSpendChartSettings = .init()) {
        self.title = title
        self.account = account
        self.chart = chart
    }

    /// Missing options take their defaults. Whether the block used its own key, as versions before accounts saved
    /// it, is read where the widget's ID is known (``OpenRouterSettings/migrateOwnKeys(_:widget:)``).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = OpenRouterBalanceOptions()
        title = try container.decodeIfPresent(String.self, forKey: .title).flatMap { $0.isEmpty ? nil : $0 }
        account = container.decodeLeniently(.account, or: nil)
        chart = try container.decode(.chart, or: defaults.chart)
    }

    private enum CodingKeys: String, CodingKey {
        case title, account, chart
    }
}

// MARK: - Models

/// The order a model list shows models in.
public enum OpenRouterModelSort: String, Codable, CaseIterable, Identifiable, Sendable {
    /// When OpenRouter added them, newest first. Not when the model was released.
    case latestAdded
    case name
    /// The largest context window first.
    case context
    /// The cheapest input tokens first; models without a known price last.
    case inputPrice
    /// The cheapest output tokens first; models without a known price last.
    case outputPrice

    public var id: Self { self }
}

/// A kind of thing a model takes in or produces, as OpenRouter names it: `text`, `image`, `embeddings`, and any kind
/// OpenRouter adds later.
public struct OpenRouterModality: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var id: String { rawValue }

    public static let text = Self(rawValue: "text")
    public static let image = Self(rawValue: "image")
    public static let file = Self(rawValue: "file")
    public static let audio = Self(rawValue: "audio")
    public static let video = Self(rawValue: "video")
    public static let speech = Self(rawValue: "speech")
    public static let decisions = Self(rawValue: "decisions")
    public static let embeddings = Self(rawValue: "embeddings")
    public static let rerank = Self(rawValue: "rerank")
    public static let transcription = Self(rawValue: "transcription")

    /// What models produce, in the order OpenRouter's catalogue lists them.
    public static let knownOutputs: [Self] = [
        .text, .image, .video, .speech, .decisions, .embeddings, .rerank, .transcription, .audio,
    ]
    /// What models take in, in the order OpenRouter's catalogue lists them.
    public static let knownInputs: [Self] = [.text, .image, .file, .audio, .video]

    /// `kinds` once each: those in `known` in its order, then any others by name.
    public static func ordered(_ kinds: some Sequence<Self>, as known: [Self]) -> [Self] {
        Set(kinds).sorted { lhs, rhs in
            switch (known.firstIndex(of: lhs), known.firstIndex(of: rhs)) {
            case (let lhs?, let rhs?): lhs < rhs
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.rawValue < rhs.rawValue
            }
        }
    }
}

/// Which models a list shows, by what they produce and take in, as OpenRouter's catalogue filters them.
public struct OpenRouterModelFilter: Codable, Hashable, Sendable {
    /// What the models produce, among anything else; `nil` for any output.
    public var output: OpenRouterModality?
    /// What the models must all take in, among anything else; empty for any input.
    public var inputs: Set<OpenRouterModality>
    /// Nothing else: the models take in only ``inputs`` and produce only ``output``, where those are chosen.
    public var isExact: Bool

    public init(output: OpenRouterModality? = nil, inputs: Set<OpenRouterModality> = [], isExact: Bool = false) {
        self.output = output
        self.inputs = inputs
        self.isExact = isExact
    }

    /// Every model, including embeddings, speech, images, video and kinds OpenRouter adds later.
    public static let all = Self()
    /// Anything that produces text, whatever it takes in.
    public static let textOutput = Self(output: .text)
    /// Text in, text out, and nothing else.
    public static let textOnly = Self(output: .text, inputs: [.text], isExact: true)

    /// Whether it lets every model through.
    public var isAll: Bool { output == nil && inputs.isEmpty }

    /// The same filter, producing `output` instead.
    public func producing(_ output: OpenRouterModality?) -> Self {
        var filter = self
        filter.output = output
        return filter
    }

    /// Missing parts take their defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        output = try container.decodeIfPresent(OpenRouterModality.self, forKey: .output)
        inputs = Set(try container.decodeIfPresent([OpenRouterModality].self, forKey: .inputs) ?? [])
        isExact = try container.decode(.isExact, or: false)
    }

    /// Inputs in a stable order, so saving the configuration again doesn't change it.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(output, forKey: .output)
        try container.encode(OpenRouterModality.ordered(inputs, as: OpenRouterModality.knownInputs), forKey: .inputs)
        try container.encode(isExact, forKey: .isExact)
    }

    private enum CodingKeys: String, CodingKey {
        case output, inputs, isExact
    }
}

/// How much each row of a model list shows.
public enum OpenRouterRowDensity: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The name and when it was added.
    case lean
    /// Also its ID and token prices.
    case standard
    /// Also its context window, what it takes and produces, and badges.
    case detail

    public var id: Self { self }
}

/// What an OpenRouter widget shows in the minimal and bar sizes, where there's room for one value.
public enum OpenRouterGlance: String, Codable, CaseIterable, Identifiable, Sendable {
    /// What the first shown block shows: the balance if it's a Balance block, otherwise the newest model.
    case automatic
    /// The model OpenRouter added last.
    case newest
    /// How many models there are.
    case count
    /// The first Balance block's balance.
    case balance

    public var id: Self { self }
}

/// The pieces of an OpenRouter widget, arranged in its builder.
public enum OpenRouterBlock: WidgetBlockKind, Identifiable {
    /// How many models there are and when the catalogue was synced.
    case summary
    /// A list of models. A widget can have any number, each with its options in
    /// ``OpenRouterSettings/listOptions(_:)`` under this ID.
    case list(UUID)
    /// An account's balance and spending. A widget can have any number, each with its options in
    /// ``OpenRouterSettings/balanceOptions(_:)`` under this ID, and each can read another account.
    case balance(UUID)

    public static let fixedBlocks: [OpenRouterBlock] = [.summary]

    /// `summary`, `list:<UUID>` or `balance:<UUID>`.
    public init?(rawValue: String) {
        if rawValue == "summary" {
            self = .summary
        } else if let id = Self.id(in: rawValue, after: Self.listPrefix) {
            self = .list(id)
        } else if let id = Self.id(in: rawValue, after: Self.balancePrefix) {
            self = .balance(id)
        } else {
            return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .summary: "summary"
        case .list(let id): Self.listPrefix + id.uuidString
        case .balance(let id): Self.balancePrefix + id.uuidString
        }
    }

    private static let listPrefix = "list:"
    private static let balancePrefix = "balance:"

    private static func id(in rawValue: String, after prefix: String) -> UUID? {
        guard rawValue.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(rawValue.dropFirst(prefix.count)))
    }

    public var id: String { rawValue }

    public var isShownByDefault: Bool { true }

    /// Whether it shows the public model catalogue, rather than an account.
    public var showsCatalogue: Bool {
        switch self {
        case .summary, .list: true
        case .balance: false
        }
    }
}

public struct OpenRouterSummaryOptions: Codable, Hashable, Sendable {
    /// Which models the count counts.
    public var filter = OpenRouterModelFilter.all

    public init(filter: OpenRouterModelFilter = .all) {
        self.filter = filter
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filter = container.decodeLeniently(.filter, or: .all)
    }
}

/// What a Model list block shows.
public struct OpenRouterModelListOptions: Codable, Hashable, Sendable {
    /// What the builder offers for ``maximumRows``.
    public static let rowCountRange = 1...20

    /// Shown above the list; `nil` for none.
    public var title: String?
    public var sort = OpenRouterModelSort.latestAdded
    public var filter = OpenRouterModelFilter.textOutput
    public var density = OpenRouterRowDensity.standard
    /// Rows in the regular size; compact shows fewer.
    public var maximumRows = 5
    /// A badge on models OpenRouter has announced it will retire, in detail rows.
    public var showsRetiring = true

    public init(
        title: String? = nil, sort: OpenRouterModelSort = .latestAdded, filter: OpenRouterModelFilter = .textOutput,
        density: OpenRouterRowDensity = .standard, maximumRows: Int = 5, showsRetiring: Bool = true
    ) {
        self.title = title
        self.sort = sort
        self.filter = filter
        self.density = density
        self.maximumRows = maximumRows
        self.showsRetiring = showsRetiring
    }

    /// Missing options take their defaults, unknown choices don't fail the whole configuration, and a hand-edited
    /// row count is moved into range.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = OpenRouterModelListOptions()
        title = try container.decodeIfPresent(String.self, forKey: .title).flatMap { $0.isEmpty ? nil : $0 }
        sort = container.decodeLeniently(.sort, or: defaults.sort)
        filter = container.decodeLeniently(.filter, or: defaults.filter)
        density = container.decodeLeniently(.density, or: defaults.density)
        maximumRows = try container.decode(.maximumRows, or: defaults.maximumRows).clamped(to: Self.rowCountRange)
        showsRetiring = try container.decode(.showsRetiring, or: defaults.showsRetiring)
    }
}

/// Ready-made layouts for an OpenRouter widget. Each list or balance in them has a fixed ID, so choosing a preset again
/// brings back that block as it was left, rather than adding another; presets sharing a block share its options.
public enum OpenRouterPreset: String, CaseIterable, Identifiable, Sendable {
    /// The summary, then the newest text models. No key needed.
    case latest
    /// The balance, then the summary and the newest text models.
    case overview
    /// The balance and its chart alone.
    case credits
    /// Text-in, text-out models by name.
    case textOnly
    /// The summary, then the newest text models with every detail.
    case richList

    public var id: Self { self }

    /// The ID of this preset's list block, if it has one.
    public var listID: UUID? {
        switch self {
        case .latest, .overview: UUID(uuidString: "5D0F4A6E-3A55-4C1B-9C0E-6F2D2B7A0001")!
        case .textOnly: UUID(uuidString: "5D0F4A6E-3A55-4C1B-9C0E-6F2D2B7A0002")!
        case .richList: UUID(uuidString: "5D0F4A6E-3A55-4C1B-9C0E-6F2D2B7A0003")!
        case .credits: nil
        }
    }

    /// The ID of the Balance block in the presets that have one.
    public static let balanceID = UUID(uuidString: "5D0F4A6E-3A55-4C1B-9C0E-6F2D2B7A0101")!

    /// The preset whose list has `id`, if any.
    public init?(listID id: UUID) {
        guard let preset = Self.allCases.first(where: { $0.listID == id }) else { return nil }
        self = preset
    }

    /// The blocks it shows, in order.
    public var blocks: [OpenRouterBlock] {
        let list = listID.map(OpenRouterBlock.list)
        switch self {
        case .latest, .richList: return [.summary] + [list].compactMap(\.self)
        case .textOnly: return [list].compactMap(\.self)
        case .credits: return [.balance(Self.balanceID)]
        case .overview: return [.balance(Self.balanceID), .summary] + [list].compactMap(\.self)
        }
    }

    /// Its list's options until someone changes them.
    public var listOptions: OpenRouterModelListOptions {
        switch self {
        case .latest, .overview, .credits: OpenRouterModelListOptions()
        case .textOnly: OpenRouterModelListOptions(sort: .name, filter: .textOnly)
        case .richList: OpenRouterModelListOptions(density: .detail, maximumRows: 8)
        }
    }
}

/// An OpenRouter widget: the public model catalogue as a summary and lists, and the balances and spending of one or
/// more accounts. Built from blocks. Only Balance blocks need a key.
public struct OpenRouterSettings: Codable, Hashable, Sendable {
    /// What the settings offer for ``sync``, besides manual.
    public static let syncMinuteChoices = [15, 30, 60, 180, 360, 720, 1440]
    /// The span of those: a hand-edited interval is moved into it.
    public static let syncMinuteRange = 15...1440
    /// What the settings offer for ``refresh``, besides manual.
    public static let refreshMinuteChoices = [5, 15, 30, 60]
    /// The span of those: a hand-edited interval is moved into it.
    public static let refreshMinuteRange = 5...60

    /// How often the model catalogue syncs. It changes a few times a day at most.
    public var sync = RefreshCadence.minutes(1440)
    /// How often balances are fetched. Spending is fetched once a day, after midnight UTC.
    public var refresh = RefreshCadence.minutes(15)
    public var glance = OpenRouterGlance.automatic
    public var blocks = BlockLayout<OpenRouterBlock>(shown: OpenRouterPreset.latest.blocks)
    public var summary = OpenRouterSummaryOptions()
    /// Each Model list block's options, by its ID; a preset's list has its preset's options until changed.
    public private(set) var lists: [String: OpenRouterModelListOptions] = [:]
    /// Each Balance block's options, by its ID.
    public private(set) var balances: [String: OpenRouterBalanceOptions] = [:]

    public init(
        sync: RefreshCadence = .minutes(1440), refresh: RefreshCadence = .minutes(15),
        glance: OpenRouterGlance = .automatic,
        preset: OpenRouterPreset = .latest
    ) {
        self.sync = sync
        self.refresh = refresh
        self.glance = glance
        blocks = BlockLayout(shown: preset.blocks)
    }

    /// Missing options take their defaults, unknown choices don't fail the whole configuration, hand-edited intervals
    /// are moved into the ranges the settings offer, and only the blocks the layout has keep their options.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = OpenRouterSettings()
        sync = container.decodeLeniently(.sync, or: defaults.sync).clamped(to: Self.syncMinuteRange)
        refresh = container.decodeLeniently(.refresh, or: defaults.refresh).clamped(to: Self.refreshMinuteRange)
        glance = container.decodeLeniently(.glance, or: defaults.glance)
        blocks = container.decodeLeniently(.blocks, or: defaults.blocks)
        summary = try container.decode(.summary, or: defaults.summary)
        let lists = try container.decodeIfPresent([String: OpenRouterModelListOptions].self, forKey: .lists)
        self.lists = (lists ?? [:]).filter { key, _ in
            UUID(uuidString: key).map { blocks.contains(.list($0)) } ?? false
        }
        let balances = try container.decodeIfPresent([String: OpenRouterBalanceOptions].self, forKey: .balances)
        self.balances = (balances ?? [:]).filter { key, _ in
            UUID(uuidString: key).map { blocks.contains(.balance($0)) } ?? false
        }
    }

    /// The Balance blocks that used their own key, as versions before accounts saved it (`usesOwnKey`), now name
    /// the account that key becomes. Their accounts are added once the key is moved to them; a block whose key isn't
    /// there goes back to the default account.
    mutating func migrateOwnKeys(_ legacy: LegacyOpenRouterSettings, widget: UUID) {
        for (key, options) in legacy.balances where options.usesOwnKey == true {
            guard let block = UUID(uuidString: key), var current = balances[block.uuidString], current.account == nil
            else { continue }
            current.account = .migratedOpenRouterKey(widget: widget, block: block)
            balances[block.uuidString] = current
        }
    }

    // MARK: Lists

    /// A Model list block's options.
    public func listOptions(_ id: UUID) -> OpenRouterModelListOptions {
        lists[id.uuidString] ?? OpenRouterPreset(listID: id)?.listOptions ?? OpenRouterModelListOptions()
    }

    public mutating func setListOptions(_ options: OpenRouterModelListOptions, for id: UUID) {
        guard blocks.contains(.list(id)) else { return }
        lists[id.uuidString] = options
    }

    /// Adds a Model list block, shown at the end, and returns it.
    @discardableResult
    public mutating func addListBlock(_ options: OpenRouterModelListOptions = .init()) -> OpenRouterBlock {
        let id = UUID()
        blocks.add(.list(id))
        lists[id.uuidString] = options
        return .list(id)
    }

    /// The shown lists' options, in order.
    public var shownLists: [(id: UUID, options: OpenRouterModelListOptions)] {
        blocks.shownBlocks.compactMap { block in
            if case .list(let id) = block { (id, listOptions(id)) } else { nil }
        }
    }

    // MARK: Balances

    /// A Balance block's options.
    public func balanceOptions(_ id: UUID) -> OpenRouterBalanceOptions {
        balances[id.uuidString] ?? OpenRouterBalanceOptions()
    }

    public mutating func setBalanceOptions(_ options: OpenRouterBalanceOptions, for id: UUID) {
        guard blocks.contains(.balance(id)) else { return }
        balances[id.uuidString] = options
    }

    /// Adds a Balance block, shown at the end, and returns it.
    @discardableResult
    public mutating func addBalanceBlock(_ options: OpenRouterBalanceOptions = .init()) -> OpenRouterBlock {
        let id = UUID()
        blocks.add(.balance(id))
        balances[id.uuidString] = options
        return .balance(id)
    }

    /// The shown balances' options, in order.
    public var shownBalances: [(id: UUID, options: OpenRouterBalanceOptions)] {
        blocks.shownBlocks.compactMap { block in
            if case .balance(let id) = block { (id, balanceOptions(id)) } else { nil }
        }
    }

    /// Every Balance block's options, shown or hidden.
    public var allBalances: [(id: UUID, options: OpenRouterBalanceOptions)] {
        blocks.entries.compactMap { entry in
            if case .balance(let id) = entry.block { (id, balanceOptions(id)) } else { nil }
        }
    }

    // MARK: Layout

    /// Removes an added block with its options. The summary can only be hidden.
    public mutating func removeBlock(_ block: OpenRouterBlock) {
        blocks.remove(block)
        switch block {
        case .list(let id): lists[id.uuidString] = nil
        case .balance(let id): balances[id.uuidString] = nil
        case .summary: break
        }
    }

    /// Shows `preset`'s blocks and hides the rest. Its blocks keep whatever options they were left with.
    public mutating func apply(_ preset: OpenRouterPreset) {
        blocks.showOnly(preset.blocks)
    }

    /// The preset the shown blocks match, if any.
    public var preset: OpenRouterPreset? {
        OpenRouterPreset.allCases.first { blocks.shownBlocks == $0.blocks }
    }

    /// Whether any shown block shows the model catalogue.
    public var showsCatalogue: Bool {
        blocks.shownBlocks.contains(where: \.showsCatalogue)
    }

    /// Which models the glance picks the newest of, or counts: the first shown list's, otherwise every model.
    public var glanceFilter: OpenRouterModelFilter {
        shownLists.first?.options.filter ?? .all
    }

    /// What the glance shows, with ``OpenRouterGlance/automatic`` worked out: never `automatic`.
    public var resolvedGlance: OpenRouterGlance {
        guard glance == .automatic else { return glance }
        if case .balance = blocks.shownBlocks.first { return .balance }
        return .newest
    }

    /// The Balance block the glance shows: the first shown one.
    public var glanceBalance: (id: UUID, options: OpenRouterBalanceOptions)? {
        shownBalances.first
    }
}

// MARK: - Demand

/// Whose OpenRouter key something reads, until the service moves to accounts: the shared key, or a Balance block's
/// own.
public enum OpenRouterAccountID: Hashable, Sendable {
    case shared
    case own(widget: UUID, block: UUID)
}

extension OpenRouterBalanceOptions {
    /// The key this block reads, as the block `block` of the widget `widget`.
    public func account(widget: UUID, block: UUID) -> OpenRouterAccountID {
        account == .migratedOpenRouterKey(widget: widget, block: block) ? .own(widget: widget, block: block) : .shared
    }
}

/// What the widgets on screen need fetched with one account's key.
public struct OpenRouterAccountDemand: Equatable, Sendable {
    /// The account's balance; `nil` while nobody shows it.
    public var balance: RefreshCadence?
    /// Spending by day, for each scope a chart shows.
    public var activity: [OpenRouterSpendScope: RefreshCadence]

    public init(balance: RefreshCadence? = nil, activity: [OpenRouterSpendScope: RefreshCadence] = [:]) {
        self.balance = balance
        self.activity = activity
    }

    /// Nothing to fetch.
    public var isEmpty: Bool { balance == nil && activity.isEmpty }

    public mutating func merge(_ other: OpenRouterAccountDemand) {
        balance = balance.merged(with: other.balance)
        activity.merge(other.activity) { $0.merged(with: $1) }
    }
}

/// What the OpenRouter widgets on screen need fetched, merged across widgets so one request serves them all.
public struct OpenRouterDemand: Equatable, Sendable {
    /// The public model catalogue; `nil` while nobody shows it.
    public var catalogue: RefreshCadence?
    /// What each account needs fetched; accounts nobody shows aren't listed.
    public var accounts: [OpenRouterAccountID: OpenRouterAccountDemand]
    /// Accounts a Balance block in the configuration reads, shown or not: what they showed is worth keeping, and a
    /// block's own key stays saved. Once no block reads an account, what it showed is forgotten, and its own key is
    /// removed from the keychain.
    public var keptAccounts: Set<OpenRouterAccountID>

    public init(
        catalogue: RefreshCadence? = nil, accounts: [OpenRouterAccountID: OpenRouterAccountDemand] = [:],
        keptAccounts: Set<OpenRouterAccountID> = []
    ) {
        self.catalogue = catalogue
        self.accounts = accounts.filter { !$0.value.isEmpty }
        self.keptAccounts = keptAccounts
    }

    /// Nothing to fetch.
    public var isEmpty: Bool { catalogue == nil && accounts.isEmpty }

    /// Whether anything needs an account's key.
    public var needsAccount: Bool { !accounts.isEmpty }

    /// What `account` needs fetched.
    public func account(_ account: OpenRouterAccountID) -> OpenRouterAccountDemand {
        accounts[account] ?? OpenRouterAccountDemand()
    }

    /// Nothing at all unless OpenRouter widgets are among `kinds`.
    public func limited(to kinds: Set<WidgetKind>) -> OpenRouterDemand {
        kinds.contains(.openRouter) ? self : OpenRouterDemand()
    }

    public mutating func merge(_ other: OpenRouterDemand) {
        catalogue = catalogue.merged(with: other.catalogue)
        accounts.merge(other.accounts) { mine, theirs in
            var merged = mine
            merged.merge(theirs)
            return merged
        }
        keptAccounts.formUnion(other.keptAccounts)
    }

    private mutating func add(_ demand: OpenRouterAccountDemand, for account: OpenRouterAccountID) {
        guard !demand.isEmpty else { return }
        accounts[account, default: OpenRouterAccountDemand()].merge(demand)
    }

    /// What `widget` needs, drawn on `panel`: its glance in bars and minimal columns, its shown blocks otherwise.
    public mutating func add(_ widget: WidgetInstance, on panel: ShownPanel) {
        guard case .openRouter(let settings) = widget.settings else { return }
        guard panel.showsBlocks else {
            switch settings.resolvedGlance {
            case .automatic, .newest, .count:
                catalogue = catalogue.merged(with: settings.sync)
            case .balance:
                if let (id, options) = settings.glanceBalance {
                    add(
                        OpenRouterAccountDemand(balance: settings.refresh),
                        for: options.account(widget: widget.id, block: id))
                }
            }
            return
        }
        if settings.showsCatalogue { catalogue = catalogue.merged(with: settings.sync) }
        for (id, options) in settings.shownBalances {
            var demand = OpenRouterAccountDemand(balance: settings.refresh)
            if let scope = options.chart.spendScope { demand.activity[scope] = settings.refresh }
            add(demand, for: options.account(widget: widget.id, block: id))
        }
    }
}

/// A panel on screen, as far as what its widgets need goes.
public struct ShownPanel: Hashable, Sendable {
    public var position: PanelPosition
    /// How densely a side panel draws its widgets; ignored for bars.
    public var density: WidgetDensity

    public init(position: PanelPosition, density: WidgetDensity) {
        self.position = position
        self.density = density
    }

    /// Bars and minimal columns show a widget's glance only, not its blocks.
    public var showsBlocks: Bool { !position.isBar && density != .minimal }
}

extension AppConfiguration {
    /// What the OpenRouter widgets on `panels` need.
    ///
    /// While `previewsEveryWidget` (the Widgets window is open), the widgets in the configuration that show models
    /// count too, so their previews show the live public catalogue; otherwise only those `previewing` (the one a
    /// builder edits). Balances in previews never do: they show an example, and never read a key or ask OpenRouter
    /// about an account. Widgets not in the configuration never count.
    public func openRouterDemand(
        panels: [ShownPanel], previewsEveryWidget: Bool = false, previewing: Set<WidgetInstance.ID> = []
    ) -> OpenRouterDemand {
        var demand = OpenRouterDemand(keptAccounts: openRouterAccounts)
        for panel in panels {
            for widget in widgets where widget.isVisible(at: panel.position) {
                demand.add(widget, on: panel)
            }
        }
        for widget in widgets where previewsEveryWidget || previewing.contains(widget.id) {
            guard case .openRouter(let settings) = widget.settings else { continue }
            if settings.showsCatalogue || settings.resolvedGlance != .balance {
                demand.catalogue = demand.catalogue.merged(with: settings.sync)
            }
        }
        return demand
    }

    /// The accounts every Balance block in the configuration reads, shown or hidden.
    public var openRouterAccounts: Set<OpenRouterAccountID> {
        var accounts = Set<OpenRouterAccountID>()
        for widget in widgets {
            guard case .openRouter(let settings) = widget.settings else { continue }
            for (id, options) in settings.allBalances {
                accounts.insert(options.account(widget: widget.id, block: id))
            }
        }
        return accounts
    }
}
