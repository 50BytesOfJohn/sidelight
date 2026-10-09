import SwiftUI

/// The long-lived objects views depend on, handed to SwiftUI through the environment.
struct AppEnvironment {
    let configurationStore: ConfigurationStore
    let displays: DisplayMonitor
    let desktopPictures: DesktopPictures
    let calendar: CalendarService
    let codex: CodexService
    let nowPlaying: NowPlayingService
    let agentEvents: AgentEventServer
    let systemStats: SystemStatsService
    let hotkeys: HotkeyCenter
    let windowAvoider: WindowAvoider
    let loginItem: LoginItem
    let rectangle: RectangleIntegration
}

extension View {
    func environment(_ app: AppEnvironment) -> some View {
        environment(app.configurationStore)
            .environment(app.displays)
            .environment(app.desktopPictures)
            .environment(app.calendar)
            .environment(app.codex)
            .environment(app.nowPlaying)
            .environment(app.agentEvents)
            .environment(app.systemStats)
            .environment(app.hotkeys)
            .environment(app.windowAvoider)
            .environment(app.loginItem)
            .environment(app.rectangle)
    }
}
