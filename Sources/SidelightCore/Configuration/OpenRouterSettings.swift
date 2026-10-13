import Foundation

// MARK: - Credits

/// Whose spending an OpenRouter Credits widget charts: the whole account, or one of its API keys.
public enum OpenRouterChartScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case account
    case key

    public var id: Self { self }
}

/// The spending chart under the balance: one bar per completed UTC day.
public struct OpenRouterSpendChartSettings: Codable, Hashable, Sendable {
    /// What the settings offer for ``days``.
    public static let dayChoices = [7, 14, 30]
    /// OpenRouter reports the last 30 completed UTC days.
    public static let dayRange = 1...30

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

/// An OpenRouter Credits widget: the account's balance, and optionally what it spent day by day.
public struct OpenRouterCreditsSettings: Codable, Hashable, Sendable {
    /// What the settings offer for ``refresh``, besides manual.
    public static let refreshMinuteChoices = [5, 15, 30, 60]

    public var refresh = RefreshCadence.minutes(15)
    public var chart = OpenRouterSpendChartSettings()

    public init(refresh: RefreshCadence = .minutes(15), chart: OpenRouterSpendChartSettings = .init()) {
        self.refresh = refresh
        self.chart = chart
    }

    /// Missing options take their defaults, and an unreadable interval doesn't fail the whole configuration.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = OpenRouterCreditsSettings()
        refresh = container.decodeLeniently(.refresh, or: defaults.refresh).clamped(to: UsageRefresh.minuteRange)
        chart = try container.decode(.chart, or: defaults.chart)
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

/// Which models a list shows, by what they take and produce.
public enum OpenRouterModelFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Text in, text out, and nothing else.
    case textOnly
    /// Anything that produces text, whatever it takes in.
    case textOutput
    /// Every model, including embeddings, speech, images, video and kinds OpenRouter adds later.
    case all

    public var id: Self { self }
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

/// What an OpenRouter Models widget shows in the minimal and bar sizes, where there's room for one value.
public enum OpenRouterModelsGlance: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The model OpenRouter added last.
    case newest
    /// How many models there are.
    case count

    public var id: Self { self }
}

/// The pieces of an OpenRouter Models widget, arranged in its builder.
public enum OpenRouterModelsBlock: WidgetBlockKind, Identifiable {
    /// How many models there are and when the catalogue was synced.
    case summary
    /// A list of models. A widget can have any number, each with its options in
    /// ``OpenRouterModelsSettings/listOptions(_:)`` under this ID.
    case list(UUID)

    public static let fixedBlocks: [OpenRouterModelsBlock] = [.summary]

    /// `summary`, or `list:<UUID>`.
    public init?(rawValue: String) {
        if rawValue == "summary" {
            self = .summary
            return
        }
        guard rawValue.hasPrefix(Self.listPrefix),
            let id = UUID(uuidString: String(rawValue.dropFirst(Self.listPrefix.count)))
        else { return nil }
        self = .list(id)
    }

    public var rawValue: String {
        switch self {
        case .summary: "summary"
        case .list(let id): Self.listPrefix + id.uuidString
        }
    }

    private static let listPrefix = "list:"

    public var id: String { rawValue }

    public var isShownByDefault: Bool { true }
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

/// Ready-made layouts for an OpenRouter Models widget. Each has its own list block with a fixed ID, so choosing
/// a preset again brings back that list as it was left, rather than adding another.
public enum OpenRouterModelsPreset: String, CaseIterable, Identifiable, Sendable {
    /// The summary, then the newest text models.
    case latest
    /// Text-in, text-out models by name.
    case textOnly
    /// The summary, then the newest text models with every detail.
    case richList

    public var id: Self { self }

    /// The ID of this preset's list block.
    public var listID: UUID {
        switch self {
        case .latest: UUID(uuidString: "5D0F4A6E-3A55-4C1B-9C0E-6F2D2B7A0001")!
        case .textOnly: UUID(uuidString: "5D0F4A6E-3A55-4C1B-9C0E-6F2D2B7A0002")!
        case .richList: UUID(uuidString: "5D0F4A6E-3A55-4C1B-9C0E-6F2D2B7A0003")!
        }
    }

    /// The preset whose list has `id`, if any.
    public init?(listID id: UUID) {
        guard let preset = Self.allCases.first(where: { $0.listID == id }) else { return nil }
        self = preset
    }

    /// The blocks it shows, in order.
    public var blocks: [OpenRouterModelsBlock] {
        switch self {
        case .latest, .richList: [.summary, .list(listID)]
        case .textOnly: [.list(listID)]
        }
    }

    /// Its list's options until someone changes them.
    public var listOptions: OpenRouterModelListOptions {
        switch self {
        case .latest: OpenRouterModelListOptions()
        case .textOnly: OpenRouterModelListOptions(sort: .name, filter: .textOnly)
        case .richList: OpenRouterModelListOptions(density: .detail, maximumRows: 8)
        }
    }
}

/// An OpenRouter Models widget: OpenRouter's public model catalogue, as a summary and lists. Built from blocks.
public struct OpenRouterModelsSettings: Codable, Hashable, Sendable {
    /// What the settings offer for ``sync``, besides manual.
    public static let syncMinuteChoices = [15, 30, 60, 180, 360]

    public var sync = RefreshCadence.minutes(60)
    public var glance = OpenRouterModelsGlance.newest
    public var blocks = BlockLayout<OpenRouterModelsBlock>(shown: OpenRouterModelsPreset.latest.blocks)
    public var summary = OpenRouterSummaryOptions()
    /// Each Model list block's options, by its ID; a preset's list has its preset's options until changed.
    public private(set) var lists: [String: OpenRouterModelListOptions] = [:]

    public init(
        sync: RefreshCadence = .minutes(60), glance: OpenRouterModelsGlance = .newest,
        preset: OpenRouterModelsPreset = .latest
    ) {
        self.sync = sync
        self.glance = glance
        blocks = BlockLayout(shown: preset.blocks)
    }

    /// Missing options take their defaults, unknown choices don't fail the whole configuration, and only the lists
    /// the layout has keep their options.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = OpenRouterModelsSettings()
        sync = container.decodeLeniently(.sync, or: defaults.sync).clamped(to: UsageRefresh.minuteRange)
        glance = container.decodeLeniently(.glance, or: defaults.glance)
        blocks = container.decodeLeniently(.blocks, or: defaults.blocks)
        summary = try container.decode(.summary, or: defaults.summary)
        let lists = try container.decodeIfPresent([String: OpenRouterModelListOptions].self, forKey: .lists)
        self.lists = (lists ?? [:]).filter { key, _ in
            UUID(uuidString: key).map { blocks.contains(.list($0)) } ?? false
        }
    }

    /// A Model list block's options.
    public func listOptions(_ id: UUID) -> OpenRouterModelListOptions {
        lists[id.uuidString] ?? OpenRouterModelsPreset(listID: id)?.listOptions ?? OpenRouterModelListOptions()
    }

    public mutating func setListOptions(_ options: OpenRouterModelListOptions, for id: UUID) {
        guard blocks.contains(.list(id)) else { return }
        lists[id.uuidString] = options
    }

    /// Adds a Model list block, shown at the end, and returns it.
    @discardableResult
    public mutating func addListBlock(_ options: OpenRouterModelListOptions = .init()) -> OpenRouterModelsBlock {
        let id = UUID()
        blocks.add(.list(id))
        lists[id.uuidString] = options
        return .list(id)
    }

    /// Removes a Model list block with its options. The summary can only be hidden.
    public mutating func removeBlock(_ block: OpenRouterModelsBlock) {
        blocks.remove(block)
        if case .list(let id) = block { lists[id.uuidString] = nil }
    }

    /// Shows `preset`'s blocks and hides the rest. Its list keeps whatever options it was left with.
    public mutating func apply(_ preset: OpenRouterModelsPreset) {
        blocks.showOnly(preset.blocks)
    }

    /// The preset the shown blocks match, if any.
    public var preset: OpenRouterModelsPreset? {
        OpenRouterModelsPreset.allCases.first { blocks.shownBlocks == $0.blocks }
    }

    /// The shown lists' options, in order.
    public var shownLists: [(id: UUID, options: OpenRouterModelListOptions)] {
        blocks.shownBlocks.compactMap { block in
            if case .list(let id) = block { (id, listOptions(id)) } else { nil }
        }
    }

    /// Which models the glance picks the newest of, or counts: the first shown list's, otherwise every model.
    public var glanceFilter: OpenRouterModelFilter {
        shownLists.first?.options.filter ?? .all
    }
}

// MARK: - Demand

/// What the OpenRouter widgets on screen need fetched, merged across widgets so one request serves them all.
public struct OpenRouterDemand: Equatable, Sendable {
    /// The public model catalogue; `nil` while nobody shows it.
    public var catalogue: RefreshCadence?
    /// The account's balance; `nil` while nobody shows it.
    public var balance: RefreshCadence?
    /// Spending by day, for each scope a chart shows.
    public var activity: [OpenRouterSpendScope: RefreshCadence]
    /// A Credits widget is in the configuration, shown or not: what the account showed is worth keeping. Once the
    /// last one is removed, it's forgotten.
    public var keepsAccountData: Bool

    public init(
        catalogue: RefreshCadence? = nil, balance: RefreshCadence? = nil,
        activity: [OpenRouterSpendScope: RefreshCadence] = [:], keepsAccountData: Bool = false
    ) {
        self.catalogue = catalogue
        self.balance = balance
        self.activity = activity
        self.keepsAccountData = keepsAccountData
    }

    /// Nothing to fetch.
    public var isEmpty: Bool { catalogue == nil && balance == nil && activity.isEmpty }

    /// Whether anything needs the account's credential.
    public var needsAccount: Bool { balance != nil || !activity.isEmpty }

    public mutating func merge(_ other: OpenRouterDemand) {
        catalogue = catalogue.merged(with: other.catalogue)
        balance = balance.merged(with: other.balance)
        activity.merge(other.activity) { $0.merged(with: $1) }
        keepsAccountData = keepsAccountData || other.keepsAccountData
    }

    /// What `widget` needs, drawn where charts do or don't fit.
    public mutating func add(_ widget: WidgetInstance, showsCharts: Bool) {
        switch widget.settings {
        case .openRouterModels(let settings):
            catalogue = catalogue.merged(with: settings.sync)
        case .openRouterCredits(let settings):
            balance = balance.merged(with: settings.refresh)
            if showsCharts, let scope = settings.chart.spendScope {
                activity[scope] = activity[scope].merged(with: settings.refresh)
            }
        default:
            break
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

    /// Bars and minimal columns show a glance only: no chart.
    public var showsCharts: Bool { !position.isBar && density != .minimal }
}

extension AppConfiguration {
    /// What the OpenRouter widgets on `panels` need. While `previewsEveryWidget`, every OpenRouter widget in the
    /// configuration counts, at its richest: the Widgets window previews them at every size. Widgets not in the
    /// configuration never count, so the gallery's previews alone never fetch, or read a credential.
    public func openRouterDemand(panels: [ShownPanel], previewsEveryWidget: Bool = false) -> OpenRouterDemand {
        var demand = OpenRouterDemand(
            keepsAccountData: widgets.contains { $0.kind == .openRouterCredits })
        if previewsEveryWidget {
            for widget in widgets { demand.add(widget, showsCharts: true) }
            return demand
        }
        for panel in panels {
            for widget in widgets where widget.isVisible(at: panel.position) {
                demand.add(widget, showsCharts: panel.showsCharts)
            }
        }
        return demand
    }
}
