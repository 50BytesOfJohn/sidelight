import Foundation

/// Stored as `{"id", "kind", "showsInSidePanel", "showsInBar", "settings"}`, where `settings` is the
/// kind-specific settings object and is omitted for kinds without settings.
extension WidgetInstance: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, showsInSidePanel, showsInBar, settings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        // Settings missing (a kind that had none when it was saved) take their defaults.
        let settings: WidgetSettings =
            switch try container.decode(WidgetKind.self, forKey: .kind) {
            case .clock: .clock(try container.decode(.settings, or: .init()))
            case .codex: .codex(try container.decode(.settings, or: .init()))
            case .claudeCode: .claudeCode(try container.decode(.settings, or: .init()))
            case .cursor: .cursor(try container.decode(.settings, or: .init()))
            case .aiUsage: .aiUsage(try container.decode(.settings, or: .init()))
            case .calendar: .calendar(try container.decode(.settings, or: .init()))
            case .nowPlaying: .nowPlaying
            case .claudeSessions: .claudeSessions(try container.decode(.settings, or: .init()))
            case .codexSessions: .codexSessions(try container.decode(.settings, or: .init()))
            case .system: .system(try container.decode(.settings, or: .init()))
            case .noodleComputer: .noodleComputer(try container.decode(.settings, or: .init()))
            case .railway: .railway(try container.decode(.settings, or: .init()))
            case .agentSessions: .agentSessions(try container.decode(.settings, or: .init()))
            case .openRouter: .openRouter(try container.decode(.settings, or: .init()))
            }
        self.init(
            id: id,
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
        case .claudeCode(let settings): try container.encode(settings, forKey: .settings)
        case .cursor(let settings): try container.encode(settings, forKey: .settings)
        case .aiUsage(let settings): try container.encode(settings, forKey: .settings)
        case .calendar(let settings): try container.encode(settings, forKey: .settings)
        case .claudeSessions(let settings): try container.encode(settings, forKey: .settings)
        case .codexSessions(let settings): try container.encode(settings, forKey: .settings)
        case .system(let settings): try container.encode(settings, forKey: .settings)
        case .noodleComputer(let settings): try container.encode(settings, forKey: .settings)
        case .railway(let settings): try container.encode(settings, forKey: .settings)
        case .agentSessions(let settings): try container.encode(settings, forKey: .settings)
        case .openRouter(let settings): try container.encode(settings, forKey: .settings)
        case .nowPlaying: break
        }
    }
}
