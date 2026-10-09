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
            nowPlaying: NowPlayingService(),
            agentEvents: AgentEventServer(),
            systemStats: SystemStatsService(),
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
        environment.nowPlaying.stop()
        environment.agentEvents.stop()
        environment.calendar.stop()
        environment.systemStats.stop()
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
    /// window (which previews every widget) is open.
    private func observeServiceDemand() {
        let store = store
        let windows = windows
        let monitor = environment.displays
        observations.append(
            Task { [weak self] in
                let demand = Observations {
                    guard !windows.isManagerOpen else { return Set(WidgetKind.allCases) }
                    let configuration = store.configuration
                    let panels = monitor.displays.map { $0.panel(in: configuration) }.filter(\.showsPanel)
                    return configuration.visibleWidgetKinds(at: panels.map(\.position))
                }
                for await kinds in demand {
                    self?.runServices(for: kinds)
                }
            }
        )
    }

    private func runServices(for kinds: Set<WidgetKind>) {
        for kind in WidgetKind.allCases {
            let isNeeded = kinds.contains(kind)
            switch kind {
            case .clock: break
            case .codex: isNeeded ? environment.codex.start() : environment.codex.stop()
            case .calendar: isNeeded ? environment.calendar.start() : environment.calendar.stop()
            case .nowPlaying: isNeeded ? environment.nowPlaying.start() : environment.nowPlaying.stop()
            case .agents: isNeeded ? environment.agentEvents.start() : environment.agentEvents.stop()
            case .system: isNeeded ? environment.systemStats.start() : environment.systemStats.stop()
            }
        }
    }
}
