import SidelightCore
import SwiftUI

/// The content of a widget for its settings and layout. Each widget's views live in its own folder.
struct WidgetContent: View {
    let settings: WidgetSettings
    let layout: WidgetLayout

    var body: some View {
        switch settings {
        case .clock(let settings): ClockWidgetView(settings: settings, layout: layout)
        case .codex(let settings): CodexWidgetView(settings: settings, layout: layout)
        case .claudeCode(let settings): ClaudeCodeWidgetView(settings: settings, layout: layout)
        case .cursor(let settings): CursorWidgetView(settings: settings, layout: layout)
        case .aiUsage(let settings): AIUsageWidgetView(settings: settings, layout: layout)
        case .calendar(let settings): CalendarWidgetView(settings: settings, layout: layout)
        case .nowPlaying: NowPlayingWidgetView(layout: layout)
        case .claudeSessions(let settings): ClaudeSessionsWidgetView(settings: settings, layout: layout)
        case .system(let settings): SystemWidgetView(settings: settings, layout: layout)
        case .noodleComputer(let settings): NoodleComputerWidgetView(settings: settings, layout: layout)
        case .railway(let settings): RailwayWidgetView(settings: settings, layout: layout)
        }
    }
}

/// The inspector's settings form for a widget.
struct WidgetSettingsEditor: View {
    @Binding var settings: WidgetSettings

    var body: some View {
        switch settings {
        case .clock(let settings): ClockSettingsEditor(settings: binding(settings, WidgetSettings.clock))
        case .codex(let settings): CodexSettingsEditor(settings: binding(settings, WidgetSettings.codex))
        case .claudeCode(let settings):
            ClaudeCodeSettingsEditor(settings: binding(settings, WidgetSettings.claudeCode))
        case .cursor(let settings): CursorSettingsEditor(settings: binding(settings, WidgetSettings.cursor))
        case .aiUsage(let settings): AIUsageSettingsEditor(settings: binding(settings, WidgetSettings.aiUsage))
        case .calendar(let settings): CalendarSettingsEditor(settings: binding(settings, WidgetSettings.calendar))
        case .system(let settings): SystemSettingsEditor(settings: binding(settings, WidgetSettings.system))
        case .claudeSessions(let settings):
            ClaudeSessionsSettingsEditor(settings: binding(settings, WidgetSettings.claudeSessions))
        case .noodleComputer(let settings):
            NoodleComputerSettingsEditor(settings: binding(settings, WidgetSettings.noodleComputer))
        case .railway(let settings): RailwaySettingsEditor(settings: binding(settings, WidgetSettings.railway))
        case .nowPlaying: Text("No options.").foregroundStyle(.secondary)
        }
    }

    /// A binding to the settings payload of the current case. `body` re-runs on every change, so `value`
    /// is always the current payload.
    private func binding<Settings>(
        _ value: Settings,
        _ embed: @escaping (Settings) -> WidgetSettings
    ) -> Binding<Settings> {
        Binding(get: { value }, set: { settings = embed($0) })
    }
}

extension EnvironmentValues {
    /// When set, widgets that show the time draw this instant instead of the live time, and stop redrawing.
    /// Catalogs of many previews set it so they cost nothing while open.
    @Entry var frozenDate: Date?
}
