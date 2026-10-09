import Foundation
import SidelightCore

/// A family of looks shared by every widget, so styles group the same way across widgets and a theme can later
/// pick each widget's style of one family.
enum StyleFamily: String, CaseIterable, Identifiable {
    case modern, classic, retro

    var id: Self { self }

    var title: String { rawValue.capitalized }
}

/// One look a widget offers. Its options live in the widget's settings, under the style.
struct WidgetStyle: Identifiable, Hashable {
    /// Stored in the widget's settings; the raw value of the widget's style enum.
    let id: String
    let title: String
    let summary: String
    let family: StyleFamily
    /// Extra words the style browser's search matches, besides the title, summary and family.
    var keywords: [String] = []

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return ([title, summary, family.title] + keywords).contains { $0.localizedStandardContains(query) }
    }
}

extension WidgetKind {
    /// Every look this kind offers, in the order the browser lists them. Empty for kinds with one look.
    var styles: [WidgetStyle] {
        switch self {
        case .clock: ClockStyle.allCases.map(\.widgetStyle)
        case .codex, .calendar, .nowPlaying, .agents, .system: []
        }
    }
}

extension WidgetSettings {
    /// The current style's ``WidgetStyle/id``; `nil` for kinds with one look. Setting an id the kind doesn't
    /// offer changes nothing, and each style keeps its own options.
    var styleID: String? {
        get {
            switch self {
            case .clock(let settings): settings.style.rawValue
            case .codex, .calendar, .nowPlaying, .agents, .system: nil
            }
        }
        set {
            switch self {
            case .clock(var settings):
                guard let style = newValue.flatMap(ClockStyle.init(rawValue:)) else { return }
                settings.style = style
                self = .clock(settings)
            case .codex, .calendar, .nowPlaying, .agents, .system:
                break
            }
        }
    }

    /// These settings with `style` picked and everything else unchanged.
    func with(_ style: WidgetStyle) -> WidgetSettings {
        var settings = self
        settings.styleID = style.id
        return settings
    }
}
