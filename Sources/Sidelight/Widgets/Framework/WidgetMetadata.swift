import SidelightCore
import SwiftUI

/// How a widget kind presents itself in the gallery, the inspector and card headers.
struct WidgetMetadata {
    let title: String
    let systemImage: String
    let tint: Color
    let summary: String
}

extension WidgetKind {
    var metadata: WidgetMetadata {
        switch self {
        case .clock: .clock
        case .codex: .codex
        case .claudeCode: .claudeCode
        case .cursor: .cursor
        case .aiUsage: .aiUsage
        case .calendar: .calendar
        case .nowPlaying: .nowPlaying
        case .claudeSessions: .claudeSessions
        case .system: .system
        }
    }
}

extension WidgetSettings {
    /// One-line description of this instance's settings, shown in the widget list.
    var summary: String {
        switch self {
        case .clock(let settings): settings.summary
        case .codex(let settings): settings.summary
        case .claudeCode(let settings): settings.summary
        case .cursor(let settings): settings.summary
        case .aiUsage(let settings): settings.summary
        case .calendar(let settings): settings.summary
        case .claudeSessions(let settings): settings.summary
        case .system(let settings): settings.summary
        case .nowPlaying: kind.metadata.summary
        }
    }
}
