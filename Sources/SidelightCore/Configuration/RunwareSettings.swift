import Foundation

/// The pieces of a Runware widget, arranged in its builder.
public enum RunwareBlock: String, WidgetBlockKind, CaseIterable, Identifiable {
    /// The balance, free credits, and how fresh they are.
    case balance
    /// Spend and requests today, over 7 days and over 30 days.
    case usage
    /// Spend or requests by UTC day.
    case chart
    /// The models that spent most over 30 days.
    case models

    public static let fixedBlocks: [RunwareBlock] = [.balance, .usage, .chart, .models]

    public var id: Self { self }

    public var isShownByDefault: Bool { true }

    /// Whether it shows the 30-day activity, rather than the account details.
    public var needsActivity: Bool { self == .chart || self == .models }
}

/// Ready-made layouts for a Runware widget.
public enum RunwarePreset: String, CaseIterable, Identifiable, Sendable {
    /// The balance, usage and the spending chart.
    case overview
    /// The balance alone: the small card.
    case balance
    /// Every block.
    case everything

    public var id: Self { self }

    public var blocks: [RunwareBlock] {
        switch self {
        case .overview: [.balance, .usage, .chart]
        case .balance: [.balance]
        case .everything: [.balance, .usage, .chart, .models]
        }
    }
}

/// What a chart's bars measure.
public enum RunwareChartMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case spend
    case requests

    public var id: Self { self }
}

public struct RunwareBalanceOptions: Codable, Hashable, Sendable {
    /// Shown above the balance in place of `Runware · <organization>`; `nil` for that.
    public var title: String?
    /// Free credits under the balance, when there are any.
    public var showsFreeCredits = true

    public init(title: String? = nil, showsFreeCredits: Bool = true) {
        self.title = title
        self.showsFreeCredits = showsFreeCredits
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title).flatMap { $0.isEmpty ? nil : $0 }
        showsFreeCredits = try container.decode(.showsFreeCredits, or: true)
    }
}

public struct RunwareChartOptions: Codable, Hashable, Sendable {
    /// What the builder offers for ``days``.
    public static let dayChoices = [7, 14, 30]
    /// Hand-edited numbers are moved into this: Runware reports 30 days at most.
    public static let dayRange = 7...30

    public var days = 7
    public var metric = RunwareChartMetric.spend

    public init(days: Int = 7, metric: RunwareChartMetric = .spend) {
        self.days = days
        self.metric = metric
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RunwareChartOptions()
        days = try container.decode(.days, or: defaults.days).clamped(to: Self.dayRange)
        metric = container.decodeLeniently(.metric, or: defaults.metric)
    }
}

public struct RunwareModelsOptions: Codable, Hashable, Sendable {
    /// What the builder offers for ``rowCount``.
    public static let rowCountRange = 1...10

    /// Rows in the regular size; compact shows fewer.
    public var rowCount = 3

    public init(rowCount: Int = 3) {
        self.rowCount = rowCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rowCount = try container.decode(.rowCount, or: 3).clamped(to: Self.rowCountRange)
    }
}

/// A Runware widget: whose organization, how often to ask, and which blocks to show with what options. Minimal and
/// bar sizes always show the balance.
public struct RunwareSettings: Codable, Hashable, Sendable {
    /// What the settings offer for ``refresh``, besides manual.
    public static let refreshMinuteChoices = [5, 15, 30, 60]
    /// The span of those: a hand-edited interval is moved into it.
    public static let refreshMinuteRange = 5...60
    /// The activity (chart, top models, history) is fetched at most this often, whatever ``refresh`` says.
    public static let activityMinimumMinutes = 15

    /// The Runware account it reads; `nil` for the default account.
    public var account: AccountID?
    /// How often the balance and usage are fetched while the widget is on screen.
    public var refresh = RefreshCadence.minutes(5)
    public var blocks = BlockLayout<RunwareBlock>(shown: RunwarePreset.overview.blocks)
    public var balance = RunwareBalanceOptions()
    public var chart = RunwareChartOptions()
    public var models = RunwareModelsOptions()

    public init(
        account: AccountID? = nil, refresh: RefreshCadence = .minutes(5), preset: RunwarePreset = .overview
    ) {
        self.account = account
        self.refresh = refresh
        blocks = BlockLayout(shown: preset.blocks)
    }

    /// Missing options take their defaults, unknown choices don't fail the whole configuration, and hand-edited
    /// numbers are moved into the ranges the settings offer.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RunwareSettings()
        account = container.decodeLeniently(.account, or: nil)
        refresh = container.decodeLeniently(.refresh, or: defaults.refresh).clamped(to: Self.refreshMinuteRange)
        blocks = container.decodeLeniently(.blocks, or: defaults.blocks)
        balance = container.decodeLeniently(.balance, or: defaults.balance)
        chart = container.decodeLeniently(.chart, or: defaults.chart)
        models = container.decodeLeniently(.models, or: defaults.models)
    }

    private enum CodingKeys: String, CodingKey {
        case account = "accountID"
        case refresh, blocks, balance, chart, models
    }

    /// Shows `preset`'s blocks and hides the rest.
    public mutating func apply(_ preset: RunwarePreset) {
        blocks.showOnly(preset.blocks)
    }

    /// The preset the shown blocks match, if any.
    public var preset: RunwarePreset? {
        RunwarePreset.allCases.first { blocks.shownBlocks == $0.blocks }
    }

    /// Whether a shown block needs the 30-day activity.
    public var showsActivity: Bool { blocks.shownBlocks.contains(where: \.needsActivity) }

    /// Whether a shown block needs the account details.
    public var showsDetails: Bool { blocks.shownBlocks.contains { !$0.needsActivity } }
}

// MARK: - Demand

/// What the widgets on screen need fetched with one Runware account.
public struct RunwareAccountDemand: Equatable, Sendable {
    /// The balance, rolling usage and keys; `nil` while nobody shows them.
    public var details: RefreshCadence?
    /// The 30-day activity; `nil` while nobody shows it. Fetched at most every
    /// ``RunwareSettings/activityMinimumMinutes``, whatever this says.
    public var activity: RefreshCadence?

    public init(details: RefreshCadence? = nil, activity: RefreshCadence? = nil) {
        self.details = details
        self.activity = activity
    }

    /// Nothing to fetch.
    public var isEmpty: Bool { details == nil && activity == nil }

    public mutating func merge(_ other: RunwareAccountDemand) {
        details = details.merged(with: other.details)
        activity = activity.merged(with: other.activity)
    }
}

/// What the Runware widgets on screen, and the details panel, need fetched, merged across widgets so one request
/// serves them all.
public struct RunwareDemand: Equatable, Sendable {
    /// What each account needs fetched; accounts nobody shows aren't listed.
    public var accounts: [AccountID: RunwareAccountDemand]
    /// Accounts any Runware widget in the configuration uses, shown or not: what they showed is kept.
    public var keptAccounts: Set<AccountID>
    /// A Runware widget is on screen, even one without an account to use yet: the service looks for the CLI's
    /// sign-in for it.
    public var isShown: Bool

    public init(
        accounts: [AccountID: RunwareAccountDemand] = [:], keptAccounts: Set<AccountID> = [], isShown: Bool = false
    ) {
        self.accounts = accounts.filter { !$0.value.isEmpty }
        self.keptAccounts = keptAccounts
        self.isShown = isShown || !self.accounts.isEmpty
    }

    /// Nothing to fetch.
    public var isEmpty: Bool { accounts.isEmpty }

    /// What `account` needs fetched.
    public func account(_ account: AccountID) -> RunwareAccountDemand {
        accounts[account] ?? RunwareAccountDemand()
    }

    /// Nothing at all unless Runware widgets are among `kinds`.
    public func limited(to kinds: Set<WidgetKind>) -> RunwareDemand {
        kinds.contains(.runware) ? self : RunwareDemand()
    }

    public mutating func merge(_ other: RunwareDemand) {
        accounts.merge(other.accounts) { mine, theirs in
            var merged = mine
            merged.merge(theirs)
            return merged
        }
        keptAccounts.formUnion(other.keptAccounts)
        isShown = isShown || other.isShown
    }

    /// What `widget` needs, drawn on `panel`: the balance in bars and minimal columns, its shown blocks otherwise. A
    /// widget without an account it can use fetches nothing, but is still shown.
    public mutating func add(
        _ widget: WidgetInstance, on panel: ShownPanel, in configuration: AppConfiguration, signedIn: Set<AccountID>
    ) {
        guard case .runware(let settings) = widget.settings else { return }
        isShown = true
        guard let id = configuration.resolveAccount(settings.account, at: .runware, signedIn: signedIn).accountID
        else { return }
        var demand = RunwareAccountDemand()
        if !panel.showsBlocks {
            demand.details = settings.refresh
        } else {
            if settings.showsDetails { demand.details = settings.refresh }
            if settings.showsActivity { demand.activity = settings.refresh }
        }
        guard !demand.isEmpty else { return }
        accounts[id, default: RunwareAccountDemand()].merge(demand)
    }
}

extension AppConfiguration {
    /// What the Runware widgets on `panels` need. Previews never count: they show an example, and never read a key or
    /// ask Runware anything. `signedIn` holds the app sign-ins signed in now, which decide the default account.
    public func runwareDemand(panels: [ShownPanel], signedIn: Set<AccountID> = []) -> RunwareDemand {
        var demand = RunwareDemand(keptAccounts: runwareAccounts(signedIn: signedIn))
        for panel in panels {
            for widget in widgets where widget.isVisible(at: panel.position) {
                demand.add(widget, on: panel, in: self, signedIn: signedIn)
            }
        }
        return demand
    }

    /// The accounts every Runware widget in the configuration uses, shown or hidden.
    public func runwareAccounts(signedIn: Set<AccountID> = []) -> Set<AccountID> {
        var accounts = Set<AccountID>()
        for widget in widgets {
            guard case .runware(let settings) = widget.settings,
                let id = resolveAccount(settings.account, at: .runware, signedIn: signedIn).accountID
            else { continue }
            accounts.insert(id)
        }
        return accounts
    }
}
