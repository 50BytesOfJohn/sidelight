import AppKit
import Observation
import SidelightCore
import SwiftUI
import os

/// The composition root: creates every long-lived object, wires them together, and reacts to configuration
/// changes for the parts of the app that live outside SwiftUI.
final class AppController {
    let environment: AppEnvironment
    let windows: WindowCoordinator
    private let panels: PanelCoordinator
    private var statusItem: StatusItemController?
    private var observations: [Task<Void, Never>] = []
    private let pendingAvoidance = DelayedTask()

    /// Long enough for a resize animation to finish, and for a dragged width slider to settle.
    static let avoidanceDelayAfterPanelChange: Duration = .milliseconds(600)

    private var store: ConfigurationStore { environment.configurationStore }

    init() {
        let claudeSessions = ClaudeSessionsService()
        let codexSessions = CodexSessionsService()
        let cursorChats = CursorChatsService.cursor()
        let openCodeSessions = OpenCodeSessionsService.openCode()
        let environment = AppEnvironment(
            configurationStore: ConfigurationStore(),
            displays: DisplayMonitor(),
            desktopPictures: DesktopPictures(),
            calendar: CalendarService(),
            codex: CodexService(),
            claudeCode: ClaudeCodeService(),
            cursor: CursorService(),
            nowPlaying: NowPlayingService(),
            claudeSessions: claudeSessions,
            codexSessions: codexSessions,
            cursorChats: cursorChats,
            openCodeSessions: openCodeSessions,
            agentSessions: AgentSessionSources(
                claudeCode: claudeSessions, codex: codexSessions, cursor: cursorChats, openCode: openCodeSessions),
            systemStats: SystemStatsService(),
            noodleComputer: NoodleComputerService(),
            railway: RailwayService(),
            hotkeys: HotkeyCenter(),
            windowAvoider: WindowAvoider(),
            loginItem: LoginItem(),
            rectangle: RectangleIntegration(),
            updater: Updater()
        )
        self.environment = environment
        windows = WindowCoordinator(environment: environment)
        panels = PanelCoordinator(environment: environment)
    }

    func start() {
        let configuration = store.configuration
        store.startWatchingFile()

        panels.apply(configuration, displays: environment.displays.displays)

        let avoider = environment.windowAvoider
        avoider.occupiedRegions = { [weak panels] in panels?.occupiedRegions ?? [] }
        avoider.mode = configuration.windowAvoidance
        avoider.start(promptingForAccess: true)

        environment.hotkeys.onPress = { [weak panels] in panels?.toggle() }
        environment.hotkeys.register(configuration.hotkey)

        environment.updater.onSettingsChange = { [store] in store.configuration.updates = $0 }
        environment.updater.start(with: configuration.updates)

        MainMenu.install(windows: windows)
        statusItem = StatusItemController(environment: environment, panels: panels, windows: windows)

        observeConfiguration()
        observeServiceDemand()
    }

    /// Stops helper processes and flushes unsaved configuration. Call before the app terminates.
    func stop() {
        for observation in observations { observation.cancel() }
        pendingAvoidance.cancel()
        store.flush()
        for service in environment.dataServices { service.stop() }
    }

    // MARK: Reacting to changes

    private func observeConfiguration() {
        let store = store
        let displays = environment.displays
        observations.append(
            Task { [weak self] in
                for await (configuration, displays) in Observations({ (store.configuration, displays.displays) }) {
                    self?.apply(configuration, displays: displays)
                }
            }
        )
    }

    private func apply(_ configuration: AppConfiguration, displays: [Display]) {
        let previousFrames = panels.targetFrames
        panels.apply(configuration, displays: displays)
        environment.windowAvoider.mode = configuration.windowAvoidance
        environment.hotkeys.register(configuration.hotkey)
        environment.updater.apply(configuration.updates)
        if panels.targetFrames != previousFrames { avoidWindowsAfterPanelChange() }
    }

    /// Window avoidance reacts to other windows moving; when a panel grows or moves instead, the windows it now
    /// covers are moved once it has settled.
    private func avoidWindowsAfterPanelChange() {
        let avoider = environment.windowAvoider
        pendingAvoidance.schedule(after: Self.avoidanceDelayAfterPanelChange) { avoider.avoidAllWindows() }
    }

    /// Runs each data service only while a widget that needs it is visible on some display, or while the manager
    /// window (which previews every widget) is open. Panels hidden with the shortcut show nothing, so they need
    /// nothing; nor do panels nobody has seen for a minute, on a sleeping or locked screen. Codex, Claude Code and Cursor are each needed by their own
    /// widget and by an AI Usage widget showing them; they run once for all of them, and fetch on a timer only as
    /// often as the most frequent of those that opted in asks.
    private func observeServiceDemand() {
        let store = store
        let windows = windows
        let monitor = environment.displays
        let coordinator = panels
        observations.append(
            Task { [weak self] in
                let demand = Observations {
                    let configuration = store.configuration
                    let unseen = coordinator.unseenDisplays
                    let displays = coordinator.isHidden ? [] : monitor.displays.filter { !unseen.contains($0.id) }
                    let panels = displays.map { $0.panel(in: configuration) }.filter(\.showsPanel)
                    return configuration.serviceDemand(
                        at: panels.map(\.position), previewsEveryWidget: windows.previewsEveryWidget)
                }
                for await demand in demand {
                    self?.runServices(for: demand)
                }
            }
        )
    }

    private func runServices(for demand: ServiceDemand) {
        let usage = demand.usage
        // A service that's needed fetches as often as the widgets showing it ask, and not at all if none of them
        // opted in. One that isn't needed stops and keeps its interval and last fetch, so showing its widget again
        // doesn't ask sooner than the interval.
        if usage.providers.contains(.claudeCode) {
            environment.claudeCode.refreshInterval = usage.claudeCodeRefreshMinutes.map { .seconds($0 * 60) }
        }
        if usage.providers.contains(.cursor) {
            environment.cursor.refreshInterval = usage.cursorRefreshMinutes.map { .seconds($0 * 60) }
        }
        for provider in AIUsageProvider.allCases {
            environment.usageService(for: provider).setRunning(usage.providers.contains(provider))
        }
        // Each agent's sessions are read once, for its own sessions widget and every Agent sessions widget listing it.
        for provider in AgentProvider.allCases {
            environment.sessionService(for: provider).setRunning(demand.sessions.contains(provider))
        }
        for kind in WidgetKind.allCases {
            let isNeeded = demand.kinds.contains(kind)
            switch kind {
            // Their services go by the usage demand above, which also counts AI Usage widgets.
            case .clock, .codex, .claudeCode, .cursor, .aiUsage: break
            // Theirs go by the sessions demand above.
            case .claudeSessions, .codexSessions, .agentSessions: break
            case .calendar: environment.calendar.setRunning(isNeeded)
            case .nowPlaying: environment.nowPlaying.setRunning(isNeeded)
            case .system: environment.systemStats.setRunning(isNeeded)
            case .noodleComputer:
                environment.noodleComputer.mayConnect = demand.placedKinds.contains(kind)
                environment.noodleComputer.setRunning(isNeeded)
            case .railway:
                // Not for the Widgets window's previews alone: Railway's sign-in isn't read until a widget is added.
                environment.railway.needs = demand.railway
                environment.railway.setRunning(isNeeded && !demand.railway.isEmpty)
            }
        }
    }
}
