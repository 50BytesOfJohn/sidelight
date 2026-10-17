import SidelightCore
import SwiftUI

/// How a widget kind presents itself in the gallery, the inspector and card headers.
struct WidgetMetadata {
    let title: String
    let systemImage: String
    let tint: Color
    /// A few words, without a period: what the widget shows. Gallery tiles show it on one line.
    let summary: String
    /// More about what it shows and where the data comes from, behind the inspector's ⓘ.
    var details: String?
    /// The service's logo in `ProviderLogos.xcassets`, drawn in place of ``systemImage``.
    var logo: String?
    /// Built on something new or undocumented that may still change under it. The gallery and inspector say so.
    var isBeta = false
}

/// Marks a widget kind as beta next to its name.
struct BetaBadge: View {
    var body: some View {
        TagBadge(title: "Beta", tint: .orange)
            .help("New, and built on something that may still change")
    }
}

/// A small tinted capsule next to a name: `Beta`, `Added`.
struct TagBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
            .fixedSize()
    }
}

/// The gallery's groups of widget kinds.
enum WidgetCategory: String, CaseIterable, Identifiable {
    case agents, cloud, essentials

    var id: Self { self }

    var title: String {
        switch self {
        case .agents: "AI agents"
        case .cloud: "Cloud"
        case .essentials: "Essentials"
        }
    }

    var systemImage: String {
        switch self {
        case .agents: "sparkles"
        case .cloud: "cloud"
        case .essentials: "square.grid.2x2"
        }
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
        case .codexSessions: .codexSessions
        case .system: .system
        case .noodleComputer: .noodleComputer
        case .railway: .railway
        case .agentSessions: .agentSessions
        case .openRouter: .openRouter
        case .stash: .stash
        case .awake: .awake
        case .docker: .docker
        case .appLauncher: .appLauncher
        }
    }
}

extension WidgetKind {
    var category: WidgetCategory {
        switch self {
        case .codex, .claudeCode, .cursor, .aiUsage, .claudeSessions, .codexSessions, .agentSessions: .agents
        case .railway, .openRouter, .noodleComputer, .docker: .cloud
        case .clock, .calendar, .nowPlaying, .system, .stash, .awake, .appLauncher: .essentials
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
        case .codexSessions(let settings): settings.summary
        case .system(let settings): settings.summary
        case .noodleComputer(let settings): settings.summary
        case .railway(let settings): settings.summary
        case .agentSessions(let settings): settings.summary
        case .openRouter(let settings): settings.layoutSummary
        case .stash(let settings): settings.summary
        case .docker(let settings): settings.summary
        case .appLauncher(let settings): settings.summary
        case .nowPlaying, .awake: kind.metadata.summary
        }
    }
}
