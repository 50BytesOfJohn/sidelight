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
    private var pendingAvoidance: Task<Void, Never>?

    /// Long enough for a resize animation to finish, and for a dragged width slider to settle.
    static let avoidanceDelayAfterPanelChange: Duration = .milliseconds(600)

    private var store: ConfigurationStore { environment.configurationStore }

    init() {
        let environment = AppEnvironment(
            configurationStore: ConfigurationStore(),
            displays: DisplayMonitor(),
            desktopPictures: DesktopPictures(),
            calendar: CalendarService(),
            codex: CodexService(),
            claudeCode: ClaudeCodeService(),
            cursor: CursorService(),
            nowPlaying: NowPlayingService(),
            claudeSessions: ClaudeSessionsService(),
            systemStats: SystemStatsService(),
            noodleComputer: NoodleComputerService(),
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
        pendingAvoidance?.cancel()
        store.flush()
        environment.codex.stop()
        environment.claudeCode.stop()
        environment.cursor.stop()
        environment.nowPlaying.stop()
        environment.claudeSessions.stop()
        environment.calendar.stop()
        environment.systemStats.stop()
        environment.noodleComputer.stop()
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
        pendingAvoidance?.cancel()
        let avoider = environment.windowAvoider
        pendingAvoidance = Task {
            do { try await Task.sleep(for: Self.avoidanceDelayAfterPanelChange) } catch { return }
            avoider.avoidAllWindows()
        }
    }

    /// Runs each data service only while a widget that needs it is visible on some display, or while the manager
    /// window (which previews every widget) is open. Codex, Claude Code and Cursor are each needed by their own
    /// widget and by an AI Usage widget showing them; they run once for all of them, and fetch on a timer only as
    /// often as the most frequent of those that opted in asks.
    private func observeServiceDemand() {
        let store = store
        let windows = windows
        let monitor = environment.displays
        observations.append(
            Task { [weak self] in
                let demand = Observations {
                    let configuration = store.configuration
                    let panels = monitor.displays.map { $0.panel(in: configuration) }.filter(\.showsPanel)
                    return configuration.serviceDemand(
                        at: panels.map(\.position), previewsEveryWidget: windows.isManagerOpen)
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
        let claude = environment.claudeCode
        let cursor = environment.cursor
        if usage.providers.contains(.claudeCode) {
            claude.refreshInterval = usage.claudeCodeRefreshMinutes.map { .seconds($0 * 60) }
        }
        if usage.providers.contains(.cursor) {
            cursor.refreshInterval = usage.cursorRefreshMinutes.map { .seconds($0 * 60) }
        }
        for provider in AIUsageProvider.allCases {
            let isNeeded = usage.providers.contains(provider)
            switch provider {
            case .codex: isNeeded ? environment.codex.start() : environment.codex.stop()
            case .claudeCode: isNeeded ? claude.start() : claude.stop()
            case .cursor: isNeeded ? cursor.start() : cursor.stop()
            }
        }
        for kind in WidgetKind.allCases {
            let isNeeded = demand.kinds.contains(kind)
            switch kind {
            // Their services go by the usage demand above, which also counts AI Usage widgets.
            case .clock, .codex, .claudeCode, .cursor, .aiUsage: break
            case .calendar: isNeeded ? environment.calendar.start() : environment.calendar.stop()
            case .nowPlaying: isNeeded ? environment.nowPlaying.start() : environment.nowPlaying.stop()
            case .claudeSessions: isNeeded ? environment.claudeSessions.start() : environment.claudeSessions.stop()
            case .system: isNeeded ? environment.systemStats.start() : environment.systemStats.stop()
            case .noodleComputer:
                environment.noodleComputer.mayConnect = demand.placedKinds.contains(kind)
                isNeeded ? environment.noodleComputer.start() : environment.noodleComputer.stop()
            }
        }
    }
}
