import SidelightCore
import SwiftUI

/// How a widget kind presents itself in the gallery, the inspector and card headers.
struct WidgetMetadata {
    let title: String
    let systemImage: String
    let tint: Color
    let summary: String
    /// Built on something new or undocumented that may still change under it. The gallery and inspector say so.
    var isBeta = false
}

/// Marks a widget kind as beta next to its name.
struct BetaBadge: View {
    var body: some View {
        Text("Beta")
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(.orange.opacity(0.18)))
            .foregroundStyle(.orange)
            .help("New, and built on something that may still change")
    }
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
        case .noodleComputer: .noodleComputer
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
        case .noodleComputer(let settings): settings.summary
        case .nowPlaying: kind.metadata.summary
        }
    }
}
