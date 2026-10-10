import AppKit
import Observation
import SidelightCore
import os

/// The computers Noodle Computer lets Sidelight see, and whether each is running.
///
/// Noodle Computer (https://usenoodle.app) serves apps outside Noodle through the `noodle-computer` tool inside its
/// bundle. Its rules decide what Sidelight gets: "Allow agents" has to be on in its settings, the person is asked once
/// whether to let Sidelight in, and Sidelight sees only the computers the person lends it, each lent through a
/// question of its own. It offers no way to watch for changes, so `list` runs every ``refreshInterval``, and only
/// while Noodle Computer is open: the tool would open it otherwise. Quitting Noodle Computer stops every computer, so
/// they show as stopped until it opens again.
///
/// The tool came out in Noodle Computer 0.22 and Sidelight was built against ``testedVersion``; its output isn't a
/// documented format, so it's read leniently.
@Observable
final class NoodleComputerService {
    nonisolated static let bundleIdentifier = "com.pdparchitect.noodle.computer"
    static let testedVersion = "0.25.0"
    static let downloadURL = URL(string: "https://github.com/pdparchitect/noodle/releases/tag/computer-latest")!
    static let refreshInterval: Duration = .seconds(30)
    /// While a computer is starting, stopping or upgrading.
    static let changingRefreshInterval: Duration = .seconds(5)
    /// After failed attempts, the wait doubles up to this.
    static let maximumRetryDelay: Duration = .seconds(5 * 60)
    /// The person is asked something in Noodle Computer, so a call can wait this long before the widget says so.
    static let promptHintDelay: Duration = .seconds(3)

    enum Status: Equatable {
        case notInstalled
        /// Installed, and not open.
        case notRunning
        /// Open, and no Noodle Computer widget has been added yet to connect for.
        case waitingForWidget
        /// The first answer hasn't come yet. Noodle Computer may be asking the person whether to let Sidelight in.
        case connecting
        case connected
        case problem(NoodleComputerProblem)
    }

    private(set) var status = Status.notInstalled
    /// Most recently listed; all stopped while Noodle Computer is closed.
    private(set) var computers: [NoodleComputer] = []
    /// A call has been waiting long enough that Noodle Computer is likely asking the person something.
    private(set) var mayBeAsking = false
    private(set) var isLending = false
    /// Computers asked to start in the background that haven't answered yet.
    private(set) var startingComputers: Set<UUID> = []
    /// The installed Noodle Computer's version, when it's installed.
    private(set) var installedVersion: String?

    /// Only widgets the person placed connect; see ``ServiceDemand/placedKinds``.
    var mayConnect = false {
        didSet {
            guard mayConnect != oldValue else { return }
            restartRefreshing()
        }
    }

    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var appURL: URL?
    @ObservationIgnored private var isAppRunning = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var consecutiveFailures = 0
    /// The person didn't let Sidelight in. Asking again would ask them again, so that waits for them to choose to.
    @ObservationIgnored private var isRefused = false
    @ObservationIgnored private var workspaceObservers: [any NSObjectProtocol] = []

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
        ]
        .map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.bundleIdentifier else { return }
                MainActor.assumeIsolated { self?.appChanged() }
            }
        }
        appChanged()
    }

    func stop() {
        isEnabled = false
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers = []
        refreshTask?.cancel()
        refreshTask = nil
        mayBeAsking = false
    }

    /// Asks again now: after the person turned on Allow agents, or to be asked again whether to let Sidelight in.
    func refreshNow() {
        consecutiveFailures = 0
        isRefused = false
        if case .problem = status { status = .connecting }
        restartRefreshing(immediately: true)
    }

    // MARK: Actions

    /// Opens the computer in Noodle Computer, on its desktop or terminal, starting it (and Noodle Computer) as needed.
    func open(_ computer: NoodleComputer) {
        NSWorkspace.shared.open(computer.openURL)
    }

    func openApp() {
        guard let appURL else {
            NSWorkspace.shared.open(Self.downloadURL)
            return
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
    }

    /// Starts the computer without bringing Noodle Computer forward.
    func startInBackground(_ computer: NoodleComputer) {
        guard status == .connected, !startingComputers.contains(computer.id) else { return }
        startingComputers.insert(computer.id)
        Task {
            let result = await run(["start", "--computer", computer.id.uuidString])
            startingComputers.remove(computer.id)
            if case .failure(let problem) = result {
                Log.noodleComputer.notice("Couldn't start a computer: \(String(describing: problem), privacy: .public)")
                NSSound.beep()
            }
            restartRefreshing(immediately: true)
        }
        restartRefreshing(immediately: true)
    }

    /// Asks the person, in Noodle Computer, to lend Sidelight one of their computers.
    func lendComputer() {
        guard isAppRunning, !isLending else { return }
        isLending = true
        Task {
            let result = await run(["borrow"])
            isLending = false
            switch result {
            case .success: restartRefreshing(immediately: true)
            case .failure(.notLent), .failure(.nothingToLend): break
            case .failure(let problem):
                status = .problem(problem)
                isRefused = problem == .notAllowed
            }
        }
    }

    // MARK: Refreshing

    private func appChanged() {
        appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
        installedVersion = appURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
        let isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
        guard isRunning != isAppRunning || refreshTask == nil else { return }
        isAppRunning = isRunning
        consecutiveFailures = 0
        restartRefreshing(immediately: true)
    }

    private func restartRefreshing(immediately: Bool = false) {
        refreshTask?.cancel()
        refreshTask = nil
        mayBeAsking = false
        guard isEnabled else { return }
        guard appURL != nil else {
            status = .notInstalled
            computers = []
            return
        }
        guard isAppRunning else {
            status = .notRunning
            computers = computers.map {
                var computer = $0
                computer.state = .stopped
                return computer
            }
            return
        }
        guard mayConnect else {
            if status != .connected { status = .waitingForWidget }
            return
        }
        guard !isRefused else {
            status = .problem(.notAllowed)
            computers = []
            return
        }
        if status != .connected { status = .connecting }
        var delay = immediately ? Duration.zero : nextDelay
        refreshTask = Task { [weak self] in
            while true {
                if delay > .zero {
                    do { try await Task.sleep(for: delay, tolerance: .seconds(2)) } catch { return }
                }
                guard let self, !Task.isCancelled else { return }
                guard await list() else { return }
                delay = nextDelay
            }
        }
    }

    /// Returns whether to carry on refreshing.
    private func list() async -> Bool {
        let hint = Task {
            try await Task.sleep(for: Self.promptHintDelay)
            mayBeAsking = true
        }
        let result = await run(["list"])
        hint.cancel()
        mayBeAsking = false
        guard isEnabled, !Task.isCancelled else { return false }
        switch result {
        case .success(let listed):
            consecutiveFailures = 0
            if listed != computers { computers = listed }
            status = .connected
            return true
        case .failure(let problem):
            if status != .problem(problem) {
                Log.noodleComputer.notice(
                    "Noodle Computer didn't list computers: \(String(describing: problem), privacy: .public)")
            }
            consecutiveFailures += 1
            status = .problem(problem)
            // A one-off failure keeps the last list; with agents turned off, its states can only go stale.
            if problem == .agentsOff { computers = [] }
            guard problem != .notAllowed else {
                isRefused = true
                computers = []
                return false
            }
            return true
        }
    }

    private var nextDelay: Duration {
        guard consecutiveFailures == 0 else {
            return UsageRefresh.retryDelay(
                interval: Self.refreshInterval, consecutiveFailures: consecutiveFailures,
                maximum: Self.maximumRetryDelay)
        }
        let isChanging = computers.contains { $0.state.isChanging } || !startingComputers.isEmpty
        return isChanging ? Self.changingRefreshInterval : Self.refreshInterval
    }

    /// Runs `noodle-computer` with `arguments` and reads the computers it answers with.
    private func run(_ arguments: [String]) async -> Result<[NoodleComputer], NoodleComputerProblem> {
        guard let tool = appURL?.appending(path: "Contents/MacOS/noodle-computer", directoryHint: .notDirectory) else {
            return .failure(.failed("Noodle Computer isn't installed."))
        }
        guard let result = await ProcessRunner.result(of: tool, arguments: arguments) else {
            return .failure(.failed("Couldn't run noodle-computer."))
        }
        guard result.status == 0 else {
            return .failure(NoodleComputerProblem(message: String(decoding: result.error, as: UTF8.self)))
        }
        // `start` answers with no list.
        return .success(NoodleComputer.list(json: result.output) ?? [])
    }
}
