import Foundation

/// Everything the user can configure. Persisted as `config.json`.
public struct AppConfiguration: Codable, Equatable, Sendable {
    public static let defaultWidgets: [WidgetInstance] = [
        WidgetInstance(kind: .clock),
        WidgetInstance(kind: .codex),
        WidgetInstance(kind: .calendar),
        WidgetInstance(kind: .nowPlaying),
        WidgetInstance(kind: .agents),
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

    /// How often to ask Anthropic for Claude usage: the shortest interval of any Claude Code widget that opted in,
    /// in minutes; `nil` when none did.
    public var claudeCodeRefreshMinutes: Int? {
        widgets.compactMap { widget in
            guard case .claudeCode(let settings) = widget.settings, settings.refreshesFromAnthropic else { return nil }
            return settings.refreshMinutes
        }.min()
    }

    /// How often to ask Cursor for its usage: the shortest interval of any Cursor widget that opted in, in minutes;
    /// `nil` when none did.
    public var cursorRefreshMinutes: Int? {
        widgets.compactMap { widget in
            guard case .cursor(let settings) = widget.settings, settings.refreshesFromCursor else { return nil }
            return settings.refreshMinutes
        }.min()
    }

    /// The kinds shown by panels at any of `positions`.
    public func visibleWidgetKinds(at positions: some Sequence<PanelPosition>) -> Set<WidgetKind> {
        Set(positions.flatMap { visibleWidgets(at: $0) }.map(\.kind))
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
