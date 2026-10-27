import SidelightCore
import SwiftUI

/// The long-lived objects views depend on, handed to SwiftUI through the environment.
struct AppEnvironment {
    let configurationStore: ConfigurationStore
    /// Every account, each provider's default, and how each is doing. Never hands out a secret.
    let accounts: AccountStore
    /// Opens Settings at the Accounts pane, from a widget or its settings.
    let settingsNavigator: SettingsNavigator
    let displays: DisplayMonitor
    let desktopPictures: DesktopPictures
    let calendar: CalendarService
    let codex: CodexService
    let claudeCode: ClaudeCodeService
    let cursor: CursorService
    /// OpenCode Console workspaces' limits, for AI Usage widgets showing OpenCode.
    let openCodeUsage: OpenCodeUsageService
    let nowPlaying: NowPlayingService
    let claudeSessions: ClaudeSessionsService
    let codexSessions: CodexSessionsService
    let cursorChats: CursorChatsService
    let openCodeSessions: OpenCodeSessionsService
    /// Every agent's sessions together, from the session services above.
    let agentSessions: AgentSessionSources
    let systemStats: SystemStatsService
    let noodleComputer: NoodleComputerService
    let railway: RailwayService
    let openRouter: OpenRouterService
    /// Runware accounts' balances, usage and models, for every Runware widget and the details panel.
    let runware: RunwareService
    /// Containers in each Docker context shown, for every Docker widget and the details panel.
    let docker: DockerService
    /// Which apps are running, for every App Launcher widget and the details panel.
    let appLauncher: AppLauncherService
    /// Every stashed item, shared by every Stash widget and the details panel.
    let stash: StashStore
    /// Stashes the selection or the clipboard, on a shortcut or a button.
    let stashCapture: StashCapture
    /// The Mac's battery, for every Battery widget.
    let battery: BatteryService
    /// Keeps the Mac awake, for every Awake widget. Not a data service: it runs whether or not a widget shows.
    let awake: AwakeSession
    /// How widgets open the details panel in place of their panel.
    let details: DetailsPresenter
    let hotkeys: HotkeyCenter
    /// Whether Sidelight may move other apps' windows and read their selection.
    let accessibility: AccessibilityPermission
    let windowAvoider: WindowAvoider
    let windowPlacer: WindowPlacer
    /// Moves and resizes the frontmost window on its shortcuts. Not a data service: nothing runs between presses.
    let windowManager: WindowManager
    let loginItem: LoginItem
    let rectangle: RectangleIntegration
    let updater: Updater
}

extension AppEnvironment {
    /// Every service that runs only while a widget needs it.
    var dataServices: [any DataService] {
        [
            calendar, codex, claudeCode, cursor, openCodeUsage, nowPlaying, claudeSessions, codexSessions, cursorChats,
            openCodeSessions, systemStats, noodleComputer, railway, openRouter, runware, docker, appLauncher, battery,
        ]
    }

    func usageService(for provider: AIUsageProvider) -> any DataService {
        switch provider {
        case .codex: codex
        case .claudeCode: claudeCode
        case .cursor: cursor
        case .openCode: openCodeUsage
        }
    }

    func sessionService(for provider: AgentProvider) -> any DataService {
        switch provider {
        case .claudeCode: claudeSessions
        case .codex: codexSessions
        case .cursor: cursorChats
        case .openCode: openCodeSessions
        }
    }
}

extension View {
    func environment(_ app: AppEnvironment) -> some View {
        environment(app.configurationStore)
            .environment(app.accounts)
            .environment(app.settingsNavigator)
            .environment(app.displays)
            .environment(app.desktopPictures)
            .environment(app.calendar)
            .environment(app.codex)
            .environment(app.claudeCode)
            .environment(app.cursor)
            .environment(app.openCodeUsage)
            .environment(app.nowPlaying)
            .environment(app.claudeSessions)
            .environment(app.codexSessions)
            .environment(app.cursorChats)
            .environment(app.openCodeSessions)
            .environment(app.agentSessions)
            .environment(app.systemStats)
            .environment(app.noodleComputer)
            .environment(app.railway)
            .environment(app.openRouter)
            .environment(app.runware)
            .environment(app.docker)
            .environment(app.appLauncher)
            .environment(app.stash)
            .environment(app.stashCapture)
            .environment(app.battery)
            .environment(app.awake)
            .environment(app.details)
            .environment(app.hotkeys)
            .environment(app.accessibility)
            .environment(app.windowAvoider)
            .environment(app.windowManager)
            .environment(app.loginItem)
            .environment(app.rectangle)
            .environment(app.updater)
    }
}
