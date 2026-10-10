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
    /// The panel's sections along its edge, each with its own widgets. Every panel shows at least one.
    public var sections: [PanelSection] = [PanelSection(widgets: AppConfiguration.defaultWidgets)]
    /// Per-display overrides of ``panel``.
    public var displays: [DisplayProfile] = []

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
    /// every widget's opt-ins count, shown or hidden.
    public func serviceDemand(
        at positions: some Sequence<PanelPosition>, previewsEveryWidget: Bool = false
    ) -> ServiceDemand {
        guard !previewsEveryWidget else {
            var usage = UsageServiceDemand(widgets: widgets)
            usage.providers = Set(AIUsageProvider.allCases)
            return ServiceDemand(kinds: Set(WidgetKind.allCases), usage: usage)
        }
        let visible = visibleWidgets(at: positions)
        return ServiceDemand(kinds: Set(visible.map(\.kind)), usage: UsageServiceDemand(widgets: visible))
    }
}

extension AppConfiguration {
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
    public var usage: UsageServiceDemand

    public init(kinds: Set<WidgetKind>, usage: UsageServiceDemand) {
        self.kinds = kinds
        self.usage = usage
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
            case .clock, .calendar, .nowPlaying, .claudeSessions, .system:
                break
            }
        }
        claudeCodeRefreshMinutes = claudeMinutes.min()
        cursorRefreshMinutes = cursorMinutes.min()
    }
}
