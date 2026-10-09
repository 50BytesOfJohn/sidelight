import Foundation

/// Stored as `{"id", "kind", "showsInSidePanel", "showsInBar", "settings"}`, where `settings` is the
/// kind-specific settings object and is omitted for kinds without settings.
extension WidgetInstance: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, showsInSidePanel, showsInBar, settings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let settings: WidgetSettings =
            switch try container.decode(WidgetKind.self, forKey: .kind) {
            case .clock: .clock(try container.decode(ClockSettings.self, forKey: .settings))
            case .codex: .codex(try container.decode(CodexSettings.self, forKey: .settings))
            case .calendar: .calendar(try container.decode(CalendarSettings.self, forKey: .settings))
            case .nowPlaying: .nowPlaying
            case .agents: .agents
            case .system: .system(try container.decode(SystemStatsSettings.self, forKey: .settings))
            }
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            settings: settings,
            showsInSidePanel: try container.decode(Bool.self, forKey: .showsInSidePanel),
            showsInBar: try container.decode(Bool.self, forKey: .showsInBar)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(showsInSidePanel, forKey: .showsInSidePanel)
        try container.encode(showsInBar, forKey: .showsInBar)
        switch settings {
        case .clock(let settings): try container.encode(settings, forKey: .settings)
        case .codex(let settings): try container.encode(settings, forKey: .settings)
        case .calendar(let settings): try container.encode(settings, forKey: .settings)
        case .system(let settings): try container.encode(settings, forKey: .settings)
        case .nowPlaying, .agents: break
        }
    }
}
