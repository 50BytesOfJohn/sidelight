import Foundation

/// Everything the user can configure. Persisted as `config.json`.
public struct AppConfiguration: Codable, Equatable, Sendable {
    public static let defaultWidgets: [WidgetInstance] = [
        WidgetInstance(kind: .clock),
        WidgetInstance(kind: .codex),
        WidgetInstance(kind: .calendar),
        WidgetInstance(kind: .nowPlaying),
        WidgetInstance(kind: .claudeSessions),
        WidgetInstance(kind: .system),
    ]

    /// Position, width and visibility of the panel on every display without its own settings.
    public var panel = PanelDefaults()
    public var appearance = Appearance()
    public var windowAvoidance: WindowAvoidanceMode = .smart
    public var hotkey: Hotkey = .defaultToggle
    public var updates = UpdateSettings()
    /// The details panel widgets open in place of the side panel.
    public var details = DetailsPanelSettings()
    /// The panel's sections along its edge, each with its own widgets. Every panel shows at least one.
    public var sections: [PanelSection] = [PanelSection(widgets: AppConfiguration.defaultWidgets)]
    /// Per-display overrides of ``panel``.
    public var displays: [DisplayProfile] = []
    /// The key accounts someone added, each provider's in the order they were added. App sign-ins aren't saved:
    /// Sidelight finds them, under their fixed IDs.
    public var accounts: [Account] = []
    /// The account each provider's widgets use when they name none.
    public var defaultAccounts: [AccountProvider: AccountID] = [:]

    public init() {}

    /// The widgets shown by a panel at `position`, across sections.
    public func visibleWidgets(at position: PanelPosition) -> [WidgetInstance] {
        widgets.filter { $0.isVisible(at: position) }
    }

    /// How often to ask Anthropic for Claude usage: the shortest interval of any widget that opted in, in minutes;
    /// `nil` when none did.
    public var claudeCodeRefreshMinutes: Int? { UsageServiceDemand(widgets: widgets).claudeCodeRefreshMinutes }

    /// How often to ask Cursor for its usage: the shortest interval of any widget that opted in, in minutes; `nil`
    /// when none did.
    public var cursorRefreshMinutes: Int? { UsageServiceDemand(widgets: widgets).cursorRefreshMinutes }

    /// The kinds shown by panels at any of `positions`.
    public func visibleWidgetKinds(at positions: some Sequence<PanelPosition>) -> Set<WidgetKind> {
        Set(visibleWidgets(at: positions).map(\.kind))
    }

    /// The widgets shown by panels at any of `positions`.
    public func visibleWidgets(at positions: some Sequence<PanelPosition>) -> [WidgetInstance] {
        let positions = Set(positions)
        return widgets.filter { widget in positions.contains { widget.isVisible(at: $0) } }
    }

    /// What the data services have to do for the panels at `positions`. While `previewsEveryWidget` (the Widgets
    /// window shows a live preview of every kind, and of every widget in the configuration), all of them run, and
    /// every widget's opt-ins count, shown or hidden. Otherwise the widgets `previewing` lists (the one a builder
    /// edits) count too, shown or hidden; nothing else is previewed.
    public func serviceDemand(
        at positions: some Sequence<PanelPosition>, previewsEveryWidget: Bool = false,
        previewing: Set<WidgetInstance.ID> = []
    ) -> ServiceDemand {
        let placed = Set(widgets.map(\.kind))
        guard !previewsEveryWidget else {
            var usage = UsageServiceDemand(widgets: widgets)
            usage.providers = Set(AIUsageProvider.allCases)
            return ServiceDemand(
                kinds: Set(WidgetKind.allCases), placedKinds: placed, usage: usage,
                railway: ServiceDemand.railwayNeeds(of: widgets), sessions: Set(AgentProvider.allCases))
        }
        let shown = Set(visibleWidgets(at: positions).map(\.id)).union(previewing)
        let visible = widgets.filter { shown.contains($0.id) }
        return ServiceDemand(
            kinds: Set(visible.map(\.kind)), placedKinds: placed, usage: UsageServiceDemand(widgets: visible),
            railway: ServiceDemand.railwayNeeds(of: visible), sessions: ServiceDemand.sessionProviders(of: visible))
    }
}

extension AppConfiguration {
    private enum CodingKeys: String, CodingKey {
        case panel, appearance, windowAvoidance, hotkey, updates, details, sections, displays, accounts
        case defaultAccounts
    }

    /// Every setting released versions saved is required, as it always was. Settings added since take their
    /// defaults when missing, so a configuration saved by an earlier release still loads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        panel = try container.decode(PanelDefaults.self, forKey: .panel)
        appearance = try container.decode(Appearance.self, forKey: .appearance)
        windowAvoidance = try container.decode(WindowAvoidanceMode.self, forKey: .windowAvoidance)
        hotkey = try container.decode(Hotkey.self, forKey: .hotkey)
        updates = try container.decode(UpdateSettings.self, forKey: .updates)
        details = try container.decode(.details, or: DetailsPanelSettings())
        sections = try container.decode([PanelSection].self, forKey: .sections)
        displays = try container.decode([DisplayProfile].self, forKey: .displays)
        // An account or provider only a newer version knows is left out, rather than failing the whole file.
        let accounts = container.decodeLeniently(.accounts, or: [LenientElement<Account>]()).compactMap(\.value)
        self.accounts = accounts.filter { $0.kind == .key }.reduce(into: []) { kept, account in
            if !kept.contains(where: { $0.id == account.id }) { kept.append(account) }
        }
        let defaults = container.decodeLeniently(.defaultAccounts, or: [String: AccountID]())
        defaultAccounts = Dictionary(
            uniqueKeysWithValues: defaults.compactMap { key, id in AccountProvider(rawValue: key).map { ($0, id) } })
    }

    public init(json: Data) throws {
        self = try JSONDecoder().decode(AppConfiguration.self, from: json)
    }

    /// Pretty-printed with sorted keys, so the file diffs and hand-edits well.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// What the data services have to do for the widgets on screen.
public struct ServiceDemand: Equatable, Sendable {
    /// Kinds with a widget showing. The usage services go by ``usage`` instead.
    public var kinds: Set<WidgetKind>
    /// Kinds with a widget in the configuration, shown or not. A service that asks the person something the first
    /// time (as Noodle Computer asks whether to let Sidelight in) waits for one, rather than asking because the
    /// Widgets window previews every kind.
    public var placedKinds: Set<WidgetKind>
    public var usage: UsageServiceDemand
    /// What Railway widgets need fetched, by whose sign-in they use. Only widgets in the configuration count, even
    /// while the Widgets window previews every kind: Sidelight doesn't read the Railway CLI's sign-in until a
    /// Railway widget is added.
    public var railway: [RailwayAccountChoice: RailwayNeeds]
    /// The agents whose sessions are listed: each session service runs once for its own widget and every Agent
    /// sessions widget showing that agent.
    public var sessions: Set<AgentProvider>

    public init(
        kinds: Set<WidgetKind>, placedKinds: Set<WidgetKind>? = nil, usage: UsageServiceDemand,
        railway: [RailwayAccountChoice: RailwayNeeds] = [:], sessions: Set<AgentProvider>? = nil
    ) {
        self.kinds = kinds
        self.placedKinds = placedKinds ?? kinds
        self.usage = usage
        self.railway = railway
        self.sessions = sessions ?? Self.sessionProviders(of: kinds)
    }

    /// Only what widgets of `kinds` need: services that only other kinds of widget use don't run, previews
    /// included. Codex, Claude Code and Cursor usage run for their own widgets and AI Usage; Claude Code and Codex
    /// sessions for their own widgets and Agent sessions, which alone lists Cursor's and OpenCode's.
    public func limited(to kinds: Set<WidgetKind>) -> ServiceDemand {
        var demand = self
        demand.kinds.formIntersection(kinds)
        demand.placedKinds.formIntersection(kinds)
        demand.usage.providers = usage.providers.filter { provider in
            let kind: WidgetKind =
                switch provider {
                case .codex: .codex
                case .claudeCode: .claudeCode
                case .cursor: .cursor
                }
            return kinds.contains(kind) || kinds.contains(.aiUsage)
        }
        demand.sessions = sessions.filter { provider in
            let kind: WidgetKind? =
                switch provider {
                case .claudeCode: .claudeSessions
                case .codex: .codexSessions
                case .cursor, .openCode: nil
                }
            return kinds.contains(.agentSessions) || (kind.map { kinds.contains($0) } ?? false)
        }
        if !kinds.contains(.railway) { demand.railway = [:] }
        return demand
    }

    /// The agents whose sessions `widgets` list.
    public static func sessionProviders(of widgets: some Sequence<WidgetInstance>) -> Set<AgentProvider> {
        var providers = Set<AgentProvider>()
        for widget in widgets {
            switch widget.settings {
            case .claudeSessions: providers.insert(.claudeCode)
            case .codexSessions: providers.insert(.codex)
            case .agentSessions(let settings): providers.formUnion(settings.providers)
            case .clock, .codex, .claudeCode, .cursor, .aiUsage, .calendar, .nowPlaying, .system, .noodleComputer,
                .railway, .openRouter:
                break
            }
        }
        return providers
    }

    /// The agents whose sessions widgets of `kinds` list, each with its default agents.
    static func sessionProviders(of kinds: Set<WidgetKind>) -> Set<AgentProvider> {
        sessionProviders(of: kinds.map(WidgetInstance.init(kind:)))
    }

    /// The needs of the Railway widgets among `widgets`, merged per sign-in.
    public static func railwayNeeds(of widgets: some Sequence<WidgetInstance>) -> [RailwayAccountChoice: RailwayNeeds] {
        var needs: [RailwayAccountChoice: RailwayNeeds] = [:]
        for widget in widgets {
            guard case .railway(let settings) = widget.settings else { continue }
            needs[settings.account] = needs[settings.account].map { $0.merged(with: settings.needs) } ?? settings.needs
        }
        return needs
    }
}

/// What the Codex, Claude Code and Cursor services have to do for a set of widgets: each runs while its own widget
/// or an AI Usage widget showing it is among them, and fetches on a timer only for widgets among them that opted
/// in, as often as the most frequent one asks. One service serves every widget; none runs twice.
public struct UsageServiceDemand: Equatable, Sendable {
    public var providers: Set<AIUsageProvider> = []
    /// `nil` when no widget opted in to fetching from Anthropic.
    public var claudeCodeRefreshMinutes: Int?
    /// `nil` when no widget opted in to fetching from Cursor.
    public var cursorRefreshMinutes: Int?

    public init(
        providers: Set<AIUsageProvider> = [], claudeCodeRefreshMinutes: Int? = nil, cursorRefreshMinutes: Int? = nil
    ) {
        self.providers = providers
        self.claudeCodeRefreshMinutes = claudeCodeRefreshMinutes
        self.cursorRefreshMinutes = cursorRefreshMinutes
    }

    public init(widgets: some Sequence<WidgetInstance>) {
        var claudeMinutes: [Int] = []
        var cursorMinutes: [Int] = []
        for widget in widgets {
            switch widget.settings {
            case .codex:
                providers.insert(.codex)
            case .claudeCode(let settings):
                providers.insert(.claudeCode)
                if settings.refreshesFromAnthropic { claudeMinutes.append(settings.refreshMinutes) }
            case .cursor(let settings):
                providers.insert(.cursor)
                if settings.refreshesFromCursor { cursorMinutes.append(settings.refreshMinutes) }
            case .aiUsage(let settings):
                providers.formUnion(settings.providers)
                claudeMinutes += [settings.claudeRefreshMinutesIfOptedIn].compactMap(\.self)
                cursorMinutes += [settings.cursorRefreshMinutesIfOptedIn].compactMap(\.self)
            case .clock, .calendar, .nowPlaying, .claudeSessions, .codexSessions, .system, .noodleComputer, .railway,
                .agentSessions, .openRouter:
                break
            }
        }
        claudeCodeRefreshMinutes = claudeMinutes.min()
        cursorRefreshMinutes = cursorMinutes.min()
    }
}
