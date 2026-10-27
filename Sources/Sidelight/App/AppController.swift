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
    /// The kinds of widget whose data services may run; `nil` for every kind.
    private let serviceKinds: Set<WidgetKind>?

    private var store: ConfigurationStore { environment.configurationStore }

    init(composition: AppComposition = .standard) {
        let claudeSessions = ClaudeSessionsService()
        let codexSessions = CodexSessionsService()
        let cursorChats = CursorChatsService.cursor()
        let openCodeSessions = OpenCodeSessionsService.openCode()
        let configurationStore = ConfigurationStore(fileURL: composition.configurationFile)
        let keyring = AccountKeyring(secrets: composition.accountSecrets)
        let accounts = AccountStore(configuration: configurationStore, keyring: keyring)
        let accountAccess = AccountAccess(keyring: keyring, accounts: accounts)
        let accessibility = AccessibilityPermission()
        let windowPlacer = WindowPlacer()
        let windowAvoider = WindowAvoider(
            permission: accessibility, placer: windowPlacer, includes: composition.movesWindows)
        let stash = StashStore(
            fileURL: composition.stashFile, deleteDoneAfter: configurationStore.configuration.stash.deleteDonePeriod)
        stash.order = configurationStore.configuration.stash.order
        let environment = AppEnvironment(
            configurationStore: configurationStore,
            accounts: accounts,
            settingsNavigator: SettingsNavigator(),
            displays: DisplayMonitor(),
            desktopPictures: DesktopPictures(),
            calendar: CalendarService(),
            codex: CodexService(accounts: accountAccess),
            claudeCode: ClaudeCodeService(accounts: accountAccess),
            cursor: CursorService(accounts: accountAccess),
            openCodeUsage: OpenCodeUsageService(accounts: accountAccess),
            nowPlaying: NowPlayingService(),
            claudeSessions: claudeSessions,
            codexSessions: codexSessions,
            cursorChats: cursorChats,
            openCodeSessions: openCodeSessions,
            agentSessions: AgentSessionSources(
                claudeCode: claudeSessions, codex: codexSessions, cursor: cursorChats, openCode: openCodeSessions),
            systemStats: SystemStatsService(),
            noodleComputer: NoodleComputerService(),
            railway: RailwayService(accounts: accountAccess),
            openRouter: OpenRouterService(transport: composition.openRouterTransport, accounts: accountAccess),
            runware: RunwareService(transport: composition.runwareTransport, accounts: accountAccess),
            docker: DockerService(transport: composition.dockerTransport),
            appLauncher: AppLauncherService(source: composition.appLauncherSource ?? .workspace),
            stash: stash,
            stashCapture: StashCapture(store: stash, configuration: configurationStore),
            battery: BatteryService(source: composition.batterySource),
            awake: AwakeSession(file: AwakeSessionFile(url: composition.awakeFile)),
            details: DetailsPresenter(),
            hotkeys: HotkeyCenter(),
            accessibility: accessibility,
            windowAvoider: windowAvoider,
            windowPlacer: windowPlacer,
            windowManager: WindowManager(permission: accessibility, placer: windowPlacer),
            loginItem: LoginItem(),
            rectangle: RectangleIntegration(),
            updater: Updater()
        )
        environment.awake.keepsDisplayOn = configurationStore.configuration.awake.keepsDisplayOn
        self.environment = environment
        serviceKinds = composition.serviceKinds
        windows = WindowCoordinator(environment: environment, placer: windowPlacer)
        environment.settingsNavigator.showSettings = { [windows] in windows.show(.settings) }
        environment.settingsNavigator.showWidgetSettings = { [windows] in windows.showSettings(forWidget: $0) }
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
        environment.windowManager.occupiedRegions = { [weak panels] in panels?.occupiedRegions ?? [] }
        // Avoidance asked for access already, unless it's off.
        environment.windowManager.apply(
            configuration.windowManager, promptingForAccess: configuration.windowAvoidance == .off)
        windows.occupiedRegions = { [weak panels] in panels?.occupiedRegions ?? [] }
        panels.onReservationsChanged = { [weak windows] in windows?.panelsChanged(settlingFor: $0) }

        var handlers: [HotkeyAction: () -> Void] = [
            .togglePanels: { [weak panels] in panels?.toggle() },
            .closeDetails: { [weak panels] in panels?.closeDetails() },
            .stashSelection: { [capture = environment.stashCapture] in capture.captureSelection() },
            .stashClipboard: { [capture = environment.stashCapture] in capture.addClipboard() },
        ]
        for action in WindowAction.allCases {
            handlers[.window(action)] = { [manager = environment.windowManager] in manager.perform(action) }
        }
        environment.hotkeys.handlers = handlers
        environment.hotkeys.register(configuration.hotkey, for: .togglePanels)
        registerStashHotkeys(for: configuration)
        registerWindowManagerHotkeys(for: configuration)

        environment.updater.onSettingsChange = { [store] in store.configuration.updates = $0 }
        environment.updater.start(with: configuration.updates)

        MainMenu.install(windows: windows)
        statusItem = StatusItemController(environment: environment, panels: panels, windows: windows)

        // Before the configuration is applied, so a configuration without an Awake widget stops it again.
        environment.awake.restore()
        observeConfiguration()
        observeServiceDemand()
    }

    /// Stops helper processes and flushes unsaved configuration. Call before the app terminates.
    func stop() {
        for observation in observations { observation.cancel() }
        // Windows the panels moved go back where they were, unless someone moved them since; then nothing is watched.
        environment.windowAvoider.releaseAll()
        environment.windowAvoider.stop()
        panels.stop()
        store.flush()
        environment.stash.flush()
        // Kept for the next launch, which picks it up again.
        environment.awake.suspend()
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

    /// Window avoidance hears of panels moving or resizing from the panels themselves, once they've settled.
    private func apply(_ configuration: AppConfiguration, displays: [Display]) {
        panels.apply(configuration, displays: displays)
        environment.windowAvoider.mode = configuration.windowAvoidance
        let windowManager = configuration.windowManager
        environment.windowAvoider.screenPadding = windowManager.isEnabled ? CGFloat(windowManager.padding) : 0
        environment.windowManager.apply(configuration.windowManager)
        environment.hotkeys.register(configuration.hotkey, for: .togglePanels)
        registerStashHotkeys(for: configuration)
        registerWindowManagerHotkeys(for: configuration)
        environment.updater.apply(configuration.updates)
        environment.stash.deleteDoneAfter = configuration.stash.deleteDonePeriod
        if environment.stash.order != configuration.stash.order { environment.stash.order = configuration.stash.order }
        environment.awake.keepsDisplayOn = configuration.awake.keepsDisplayOn
        // Removing the last Awake widget leaves nothing to stop it with, so it stops too.
        if !configuration.widgets.contains(where: { $0.kind == .awake }) { environment.awake.stop() }
    }

    /// The stash's shortcuts are taken only while a Stash widget is in the configuration, shown or not, so they take
    /// nothing from other apps for someone who doesn't use it.
    private func registerStashHotkeys(for configuration: AppConfiguration) {
        let hotkeys = environment.hotkeys
        if configuration.widgets.contains(where: { $0.kind == .stash }) {
            hotkeys.register(configuration.stash.captureHotkey, for: .stashSelection)
            hotkeys.register(configuration.stash.clipboardHotkey, for: .stashClipboard)
        } else {
            hotkeys.unregister(.stashSelection)
            hotkeys.unregister(.stashClipboard)
        }
    }

    /// The window manager's shortcuts are taken only while it's on, so they take nothing from other apps otherwise.
    private func registerWindowManagerHotkeys(for configuration: AppConfiguration) {
        let settings = configuration.windowManager
        let actions = WindowAction.allCases
        if settings.isEnabled {
            environment.hotkeys.register(actions.map { (.window($0), settings[action: $0]) })
        } else {
            environment.hotkeys.unregister(actions.map(HotkeyAction.window))
        }
    }

    /// What the data services have to do, from everything on screen.
    private struct Demand: Equatable {
        var services: ServiceDemand
        var openRouter: OpenRouterDemand
        var runware: RunwareDemand
    }

    /// Runs each data service only while a widget that needs it is visible on some display, while the manager
    /// window (which previews every widget) is open, or while the builder previews it. Panels hidden with the
    /// shortcut show nothing, so they need nothing; nor do panels nobody has seen for a minute, on a sleeping or
    /// locked screen, nor a panel the details panel has stood in for a few seconds. Codex, Claude Code and Cursor are
    /// each needed by their own widget and by an AI Usage widget showing them, OpenCode by an AI Usage widget; they
    /// run once for all of them (Claude Code and OpenCode once for each account), and fetch on a timer only as often as the most frequent of those that opted in
    /// asks. The details panel needs only
    /// what it shows, while it can be seen: it's watched on its own, as the panel it covers is ordered out on
    /// purpose. A composition limited to some kinds of widget runs only their services, whatever is shown or
    /// previewed.
    private func observeServiceDemand() {
        let store = store
        let windows = windows
        let monitor = environment.displays
        let coordinator = panels
        let kinds = serviceKinds
        let accounts = environment.accounts
        observations.append(
            Task { [weak self] in
                let demand = Observations {
                    let configuration = store.configuration
                    let unseen = coordinator.unseenDisplays
                    let covered = coordinator.coveredDisplay
                    let displays =
                        coordinator.isHidden
                        ? [] : monitor.displays.filter { !unseen.contains($0.id) && $0.id != covered }
                    let panels = displays.map { (display: $0, panel: $0.panel(in: configuration)) }
                        .filter { $0.panel.showsPanel }
                    let previews = windows.previewsEveryWidget
                    let previewed = Set([windows.builderWidgetID].compactMap(\.self))
                    let shown = panels.map {
                        ShownPanel(
                            position: $0.panel.position,
                            density: PanelMetrics.columns(of: $0.panel, on: $0.display).density)
                    }
                    var openRouter = configuration.openRouterDemand(
                        panels: shown, previewsEveryWidget: previews, previewing: previewed)
                    var runware = configuration.runwareDemand(panels: shown, signedIn: accounts.signedInAppSignIns)
                    var services = configuration.serviceDemand(
                        at: panels.map(\.panel.position), previewsEveryWidget: previews, previewing: previewed,
                        signedIn: accounts.signedInAppSignIns)
                    if !coordinator.isHidden, !coordinator.isDetailsUnseen, let details = coordinator.details {
                        openRouter.merge(details.openRouterDemand(in: configuration))
                        runware.merge(details.runwareDemand(in: configuration))
                        services.docker.merge(details.dockerDemand())
                        services.appLauncher.merge(details.appLauncherDemand(in: configuration))
                    }
                    guard let kinds else { return Demand(services: services, openRouter: openRouter, runware: runware) }
                    return Demand(
                        services: services.limited(to: kinds), openRouter: openRouter.limited(to: kinds),
                        runware: runware.limited(to: kinds))
                }
                for await demand in demand {
                    self?.runServices(for: demand.services)
                    self?.runOpenRouter(for: demand.openRouter)
                    self?.runRunware(for: demand.runware)
                }
            }
        )
    }

    /// One service for every OpenRouter widget and the catalogue's details panel. Only placed widgets count, so the
    /// gallery's previews never fetch, and previews of balances never read a key.
    private func runOpenRouter(for demand: OpenRouterDemand) {
        environment.openRouter.demand = demand
        environment.openRouter.setRunning(!demand.isEmpty)
    }

    /// One service for every Runware widget and its details panel. Only placed widgets count, so previews never read
    /// a key or ask Runware anything. A shown widget without an account still runs it, to notice the CLI signing in.
    private func runRunware(for demand: RunwareDemand) {
        environment.runware.demand = demand
        environment.runware.setRunning(demand.isShown)
    }

    private func runServices(for demand: ServiceDemand) {
        let usage = demand.usage
        // A service that's needed fetches as often as the widgets showing it ask, and not at all if none of them
        // opted in. One that isn't needed stops and keeps its interval and last fetch, so showing its widget again
        // doesn't ask sooner than the interval.
        if usage.providers.contains(.claudeCode) {
            environment.claudeCode.demand = demand.claudeCode
        }
        if usage.providers.contains(.cursor) {
            environment.cursor.refreshInterval = usage.cursorRefreshMinutes.map { .seconds($0 * 60) }
        }
        if usage.providers.contains(.openCode) {
            environment.openCodeUsage.demand = demand.openCode
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
                environment.railway.needs = demand.railway.accounts
                environment.railway.setRunning(isNeeded && demand.railway.isShown)
            // Theirs goes by the OpenRouter demand, which also counts the details panel.
            case .openRouter: break
            // Theirs goes by the Runware demand, which also counts the details panel.
            case .runware: break
            // The stash is read once and changes only when someone changes it: nothing to run.
            case .stash: break
            // Keeping the Mac awake goes on while its widget is hidden or unseen: that's when it matters.
            case .awake: break
            // Battery readings need no key and cost next to nothing, so the gallery's previews show the real charge.
            case .battery:
                environment.battery.readsPower = demand.battery.readsPower
                environment.battery.setRunning(isNeeded)
            // Only placed widgets and the details panel count, so the gallery's preview never runs `docker`.
            case .docker:
                environment.docker.demand = demand.docker
                environment.docker.setRunning(!demand.docker.isEmpty)
            // The details panel counts too: it keeps running dots live while it covers the panel.
            case .appLauncher:
                environment.appLauncher.demand = demand.appLauncher
                environment.appLauncher.setRunning(!demand.appLauncher.isEmpty)
            }
        }
    }
}
