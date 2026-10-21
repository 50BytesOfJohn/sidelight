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
    /// What every Stash widget shares: capture shortcuts, deleting done items, excluded apps.
    public var stash = StashOptions()
    /// What every Awake widget shares: whether the display stays on too.
    public var awake = AwakeOptions()
    /// The shortcuts that move and resize the frontmost window, and how tiles are spaced.
    public var windowManager = WindowManagerSettings()
    /// The panel's sections along its edge, each with its own widgets. Every panel shows at least one.
    public var sections: [PanelSection] = [PanelSection(widgets: AppConfiguration.defaultWidgets)]
    /// Per-display overrides of ``panel``.
    public var displays: [DisplayProfile] = []
    /// The accounts someone added (key accounts and app profiles), each provider's in the order they were added.
    /// App sign-ins aren't saved: Sidelight finds them, under their fixed IDs.
    public var accounts: [Account] = []
    /// The account each provider's widgets use when they name none.
    public var defaultAccounts: [AccountProvider: AccountID] = [:]

    public init() {}

    /// The widgets shown by a panel at `position`, across sections.
    public func visibleWidgets(at position: PanelPosition) -> [WidgetInstance] {
        widgets.filter { $0.isVisible(at: position) }
    }

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
    ///
    /// `signedIn` holds the app sign-ins signed in now, which decide the account some widgets use.
    public func serviceDemand(
        at positions: some Sequence<PanelPosition>, previewsEveryWidget: Bool = false,
        previewing: Set<WidgetInstance.ID> = [], signedIn: Set<AccountID> = []
    ) -> ServiceDemand {
        let placed = Set(widgets.map(\.kind))
        guard !previewsEveryWidget else {
            var usage = UsageServiceDemand(widgets: widgets)
            usage.providers = Set(AIUsageProvider.allCases)
            // The gallery previews each kind on its default account.
            var claudeCode = claudeCodeDemand(of: widgets, signedIn: signedIn)
            if let id = defaultAccount(for: .claudeCode, signedIn: signedIn).accountID,
                let profile = claudeCodeProfile(id)
            {
                claudeCode[id] = claudeCode[id] ?? ClaudeCodeNeeds(profile: profile)
            }
            return ServiceDemand(
                kinds: Set(WidgetKind.allCases), placedKinds: placed, usage: usage,
                railway: railwayDemand(of: widgets, signedIn: signedIn), claudeCode: claudeCode,
                sessions: Set(AgentProvider.allCases),
                // As for Railway, only placed widgets count: the gallery alone never runs the CLI or wakes Docker.
                docker: dockerDemand(of: widgets),
                // Observing running apps reads nothing private, so the gallery's previews show real running dots.
                appLauncher: {
                    var demand = appLauncherDemand(of: widgets)
                    demand.isShown = true
                    return demand
                }())
        }
        let shown = Set(visibleWidgets(at: positions).map(\.id)).union(previewing)
        let visible = widgets.filter { shown.contains($0.id) }
        return ServiceDemand(
            kinds: Set(visible.map(\.kind)), placedKinds: placed, usage: UsageServiceDemand(widgets: visible),
            railway: railwayDemand(of: visible, signedIn: signedIn),
            claudeCode: claudeCodeDemand(of: visible, signedIn: signedIn),
            sessions: ServiceDemand.sessionProviders(of: visible), docker: dockerDemand(of: visible),
            appLauncher: appLauncherDemand(of: visible))
    }

    /// What the widgets among `widgets` that show Claude usage need, merged for each Claude account they use: where
    /// Claude Code keeps it, and how often to ask Anthropic, the shortest interval of those that opted in.
    public func claudeCodeDemand(
        of widgets: some Sequence<WidgetInstance>, signedIn: Set<AccountID> = []
    ) -> [AccountID: ClaudeCodeNeeds] {
        var demand: [AccountID: ClaudeCodeNeeds] = [:]
        for widget in widgets {
            // The accounts the widget shows, each with how often it asks Anthropic for them.
            let references: [AccountID?]
            let minutes: Int?
            switch widget.settings {
            case .claudeCode(let settings):
                references = [settings.account]
                minutes = settings.refreshesFromAnthropic ? settings.refreshMinutes : nil
            case .aiUsage(let settings):
                references = settings.accountReferences(shownOnly: true).filter { $0.provider == .claudeCode }
                    .map(\.account)
                minutes = settings.claudeRefreshMinutesIfOptedIn
            default:
                continue
            }
            for reference in references {
                guard let id = resolveAccount(reference, at: .claudeCode, signedIn: signedIn).accountID,
                    let profile = claudeCodeProfile(id)
                else { continue }
                let needs = ClaudeCodeNeeds(profile: profile, refreshMinutes: minutes)
                demand[id] = demand[id].map { $0.merged(with: needs) } ?? needs
            }
        }
        return demand
    }

    /// Where Claude Code keeps the Claude account `id`: its default folder for its app sign-in, or the folder an app
    /// profile was added with. `nil` for any other account.
    public func claudeCodeProfile(_ id: AccountID) -> ClaudeCodeProfile? {
        if id == .claudeCodeApp { return .standard }
        guard let account = accounts.first(where: { $0.id == id }), account.provider == .claudeCode,
            account.kind == .appProfile, let folder = account.folder
        else { return nil }
        return ClaudeCodeProfile(configDirectory: folder)
    }

    /// What the Railway widgets among `widgets` need, merged for each account they use. Widgets without an account
    /// they can use fetch nothing, but still count as shown: the service looks for the CLI's sign-in for them.
    public func railwayDemand(of widgets: some Sequence<WidgetInstance>, signedIn: Set<AccountID> = []) -> RailwayDemand
    {
        var demand = RailwayDemand()
        for widget in widgets {
            guard case .railway(let settings) = widget.settings else { continue }
            demand.isShown = true
            guard let id = resolveAccount(settings.account, at: .railway, signedIn: signedIn).accountID else {
                continue
            }
            demand.accounts[id] = demand.accounts[id].map { $0.merged(with: settings.needs) } ?? settings.needs
        }
        return demand
    }
}

extension AppConfiguration {
    private enum CodingKeys: String, CodingKey {
        case panel, appearance, windowAvoidance, hotkey, updates, details, stash, sections, displays, accounts
        case defaultAccounts, awake, windowManager
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
        stash = container.decodeLeniently(.stash, or: StashOptions())
        awake = container.decodeLeniently(.awake, or: AwakeOptions())
        windowManager = container.decodeLeniently(.windowManager, or: WindowManagerSettings())
        sections = try container.decode([PanelSection].self, forKey: .sections)
        displays = try container.decode([DisplayProfile].self, forKey: .displays)
        // An account or provider only a newer version knows is left out, rather than failing the whole file.
        let accounts = container.decodeLeniently(.accounts, or: [LenientElement<Account>]()).compactMap(\.value)
        // One account per ID, and one app profile per folder: two would be the same sign-in. Folders compare as
        // written, as the app hashes them: two spellings are two sign-ins to it.
        self.accounts = accounts.filter(\.isWellFormed).reduce(into: []) { kept, account in
            let isDuplicate = kept.contains { other in
                other.id == account.id
                    || account.kind == .appProfile && other.kind == .appProfile && other.provider == account.provider
                        && other.folder == account.folder
            }
            if !isDuplicate { kept.append(account) }
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
    /// What Railway widgets need fetched, by the account they use. Only widgets in the configuration count, even
    /// while the Widgets window previews every kind: Sidelight doesn't read the Railway CLI's sign-in until a
    /// Railway widget is added.
    public var railway: RailwayDemand
    /// What widgets showing Claude usage need, by the Claude account they use.
    public var claudeCode: [AccountID: ClaudeCodeNeeds]
    /// The agents whose sessions are listed: each session service runs once for its own widget and every Agent
    /// sessions widget showing that agent.
    public var sessions: Set<AgentProvider>
    /// The Docker contexts widgets show. Only widgets in the configuration count, even while the Widgets window
    /// previews every kind: the gallery's preview alone never runs `docker`.
    public var docker: DockerDemand
    /// Whether a launcher is shown, and the apps they pin.
    public var appLauncher: AppLauncherDemand

    public init(
        kinds: Set<WidgetKind>, placedKinds: Set<WidgetKind>? = nil, usage: UsageServiceDemand,
        railway: RailwayDemand = RailwayDemand(), claudeCode: [AccountID: ClaudeCodeNeeds] = [:],
        sessions: Set<AgentProvider>? = nil, docker: DockerDemand = DockerDemand(),
        appLauncher: AppLauncherDemand = AppLauncherDemand()
    ) {
        self.kinds = kinds
        self.placedKinds = placedKinds ?? kinds
        self.usage = usage
        self.railway = railway
        self.claudeCode = claudeCode
        self.sessions = sessions ?? Self.sessionProviders(of: kinds)
        self.docker = docker
        self.appLauncher = appLauncher
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
        if !kinds.contains(.railway) { demand.railway = RailwayDemand() }
        if !kinds.contains(.docker) { demand.docker = DockerDemand() }
        if !kinds.contains(.appLauncher) { demand.appLauncher = AppLauncherDemand() }
        if !demand.usage.providers.contains(.claudeCode) { demand.claudeCode = [:] }
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
                .railway, .openRouter, .stash, .awake, .docker, .appLauncher, .runware:
                break
            }
        }
        return providers
    }

    /// The agents whose sessions widgets of `kinds` list, each with its default agents.
    static func sessionProviders(of kinds: Set<WidgetKind>) -> Set<AgentProvider> {
        sessionProviders(of: kinds.map(WidgetInstance.init(kind:)))
    }

}

/// What the Codex, Claude Code and Cursor services have to do for a set of widgets: each runs while its own widget
/// or an AI Usage widget showing it is among them, and fetches on a timer only for widgets among them that opted
/// in, as often as the most frequent one asks. One service serves every widget; none runs twice. Claude Code fetches
/// for each account on its own (see ``ServiceDemand/claudeCode``).
public struct UsageServiceDemand: Equatable, Sendable {
    public var providers: Set<AIUsageProvider> = []
    /// `nil` when no widget opted in to fetching from Cursor.
    public var cursorRefreshMinutes: Int?

    public init(providers: Set<AIUsageProvider> = [], cursorRefreshMinutes: Int? = nil) {
        self.providers = providers
        self.cursorRefreshMinutes = cursorRefreshMinutes
    }

    public init(widgets: some Sequence<WidgetInstance>) {
        var cursorMinutes: [Int] = []
        for widget in widgets {
            switch widget.settings {
            case .codex:
                providers.insert(.codex)
            case .claudeCode:
                providers.insert(.claudeCode)
            case .cursor(let settings):
                providers.insert(.cursor)
                if settings.refreshesFromCursor { cursorMinutes.append(settings.refreshMinutes) }
            case .aiUsage(let settings):
                providers.formUnion(settings.shownProviders)
                cursorMinutes += [settings.cursorRefreshMinutesIfOptedIn].compactMap(\.self)
            case .clock, .calendar, .nowPlaying, .claudeSessions, .codexSessions, .system, .noodleComputer, .railway,
                .agentSessions, .openRouter, .stash, .awake, .docker, .appLauncher, .runware:
                break
            }
        }
        cursorRefreshMinutes = cursorMinutes.min()
    }
}

/// What widgets showing Claude usage need from one Claude account: where Claude Code keeps it, and how often to ask
/// Anthropic for its usage, `nil` when none of them opted in.
public struct ClaudeCodeNeeds: Equatable, Sendable {
    public var profile: ClaudeCodeProfile
    public var refreshMinutes: Int?

    public init(profile: ClaudeCodeProfile, refreshMinutes: Int? = nil) {
        self.profile = profile
        self.refreshMinutes = refreshMinutes
    }

    /// Both widgets' needs: the more frequent interval asked for.
    public func merged(with other: ClaudeCodeNeeds) -> ClaudeCodeNeeds {
        var merged = self
        merged.refreshMinutes = [refreshMinutes, other.refreshMinutes].compactMap(\.self).min()
        return merged
    }
}
