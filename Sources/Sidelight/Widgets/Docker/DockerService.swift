import AppKit
import Observation
import SidelightCore
import os

/// Lines from a running `docker events`, and a way to end it.
struct DockerEventStream: Sendable {
    let lines: AsyncStream<Data>
    let terminate: @Sendable () -> Void
}

/// Containers in each Docker context a widget or the details panel shows, through the `docker` CLI.
///
/// Each context has one ``DockerConnection``, shared by every widget showing it. A connection listens to
/// `docker events` instead of polling, and reads the containers again only when something happens. Nothing here
/// ever starts Docker, or asks it for more than containers: `docker info`, `version` and `desktop start` are never
/// run. CPU and memory are read only for the context the details panel shows, while it's open.
@Observable
final class DockerService: DataService {
    /// How the service runs `docker`; tests stand in a script of their own.
    struct Transport {
        /// Runs `docker` with these arguments to completion; `nil` when it couldn't be started.
        var run: @Sendable ([String]) async -> ProcessRunner.Result?
        /// Starts a long-running `docker` with these arguments, such as `docker events`.
        var stream: @Sendable ([String]) throws -> DockerEventStream

        static func cli(_ executable: URL) -> Transport {
            Transport(
                run: { arguments in await ProcessRunner.result(of: executable, arguments: arguments) },
                stream: { arguments in
                    let process = try ChildProcess(executable: executable, arguments: arguments)
                    return DockerEventStream(lines: process.lines, terminate: { process.terminate() })
                })
        }
    }

    /// Where Docker Desktop and OrbStack are, by bundle identifier: the apps that can be opened for a stopped context.
    static let runtimeApps: [(name: String, bundleIdentifier: String)] = [
        ("Docker Desktop", "com.docker.docker"), ("OrbStack", "dev.kdrag0n.MacVirt"),
    ]

    /// No `docker` was found in the places it's installed.
    private(set) var cliMissing = false
    /// Every context the CLI knows, for the picker and the current context's name.
    private(set) var contexts: [DockerContext] = []
    /// The contexts shown, and which one's stats are read. Connections not in it stop, and keep what they read.
    var demand = DockerDemand() {
        didSet {
            guard demand != oldValue else { return }
            reconcile()
        }
    }

    /// One per context, created when first needed.
    private var connections: [DockerContextChoice: DockerConnection] = [:]

    @ObservationIgnored private let fixedTransport: Transport?
    @ObservationIgnored private var transport: Transport?
    @ObservationIgnored private let timing: DockerConnection.Timing
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var configWatcher: FileWatcher?
    @ObservationIgnored private let contextReload = CoalescedReload()

    /// - Parameter transport: How to run `docker`; `nil` finds the CLI where it's installed.
    init(transport: Transport? = nil, timing: DockerConnection.Timing = .standard) {
        fixedTransport = transport
        self.transport = transport
        self.timing = timing
    }

    /// The connection for `choice`, once anything has shown it.
    func connection(_ choice: DockerContextChoice) -> DockerConnection? {
        connections[choice]
    }

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        locateCLI()
        guard transport != nil else { return }
        // `docker context use` writes the current context here; Docker Desktop also rewrites it as it starts.
        let config = URL.homeDirectory.appending(path: ".docker/config.json", directoryHint: .notDirectory)
        configWatcher = FileWatcher(file: config, onMainActor: { [weak self] in self?.reloadContexts() })
        reloadContexts()
        reconcile()
    }

    func stop() {
        isEnabled = false
        configWatcher = nil
        contextReload.cancel()
        for connection in connections.values { connection.stop() }
    }

    /// Tries again now, without waiting for the backoff: after installing Docker, or fixing what went wrong.
    func refreshNow() {
        guard isEnabled else { return }
        if transport == nil {
            stop()
            start()
            return
        }
        reloadContexts()
        for choice in demand.contexts { connections[choice]?.refreshNow() }
    }

    // MARK: Contexts

    /// The context `choice` resolves to now, once the contexts are read.
    func context(for choice: DockerContextChoice) -> DockerContext? {
        switch choice {
        case .current: contexts.first(where: \.isCurrent)
        case .named(let name): contexts.first { $0.name == name }
        }
    }

    /// What to call `choice`'s context: `Docker Desktop`, `OrbStack`, or its name.
    func displayName(for choice: DockerContextChoice) -> String {
        if let context = context(for: choice) { return context.displayName }
        if case .named(let name) = choice { return DockerContext(name: name).displayName }
        return "Docker"
    }

    /// The app that runs `choice`'s context, if it's one Sidelight knows and it's installed.
    func runtimeApp(for choice: DockerContextChoice) -> (name: String, url: URL)? {
        let name = context(for: choice)?.name ?? (choice == .current ? "default" : nil)
        let candidates: [String] =
            switch name {
            case "desktop-linux", "default": ["Docker Desktop"]
            case "orbstack": ["OrbStack"]
            default: []
            }
        for app in Self.runtimeApps where candidates.contains(app.name) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
                return (app.name, url)
            }
        }
        return nil
    }

    /// Opens Docker Desktop or OrbStack for `choice`. Only ever on a click: Sidelight never starts Docker itself.
    func openRuntime(for choice: DockerContextChoice) {
        guard let app = runtimeApp(for: choice) else { return }
        NSWorkspace.shared.openApplication(at: app.url, configuration: .init())
    }

    private func locateCLI() {
        guard fixedTransport == nil else { return }
        if transport == nil, let executable = DockerCLI.locate() {
            transport = .cli(executable)
            Log.docker.notice("Using docker at \(executable.path(percentEncoded: false), privacy: .public)")
        }
        cliMissing = transport == nil
    }

    private func reloadContexts() {
        contextReload.request { [weak self] in await self?.readContexts() }
    }

    private func readContexts() async {
        guard let transport else { return }
        let result = await transport.run(DockerCLI.listContexts)
        guard isEnabled, !Task.isCancelled, let result, result.status == 0 else { return }
        let listed = DockerContext.list(output: result.output)
        let previousCurrent = contexts.first(where: \.isCurrent)?.name
        if listed != contexts { contexts = listed }
        for (choice, connection) in connections { connection.socketURL = context(for: choice)?.socketURL }
        let current = listed.first(where: \.isCurrent)?.name
        // A widget following the current context follows `docker context use`.
        if let previousCurrent, previousCurrent != current, let connection = connections[.current] {
            Log.docker.notice("The current Docker context changed; reconnecting")
            connection.restart()
        }
    }

    // MARK: Connections

    private func reconcile() {
        guard isEnabled, let transport else { return }
        for choice in demand.contexts {
            let connection =
                connections[choice]
                ?? {
                    let connection = DockerConnection(choice: choice, transport: transport, timing: timing)
                    connections[choice] = connection
                    return connection
                }()
            connection.socketURL = context(for: choice)?.socketURL
            connection.samplesStats = choice == demand.stats
            connection.start()
        }
        for (choice, connection) in connections where !demand.contexts.contains(choice) {
            connection.samplesStats = false
            connection.stop()
        }
    }
}

/// The containers in one Docker context, kept up to date from its events.
///
/// It starts `docker events` first, from a second before now, then reads the containers, so nothing can happen
/// unseen between the two; the worst case is one extra read. Each event asks for another read, gathered so a burst
/// (`compose up`) costs at most two. When the events end (Docker quit, the Mac slept) it reconnects, waiting longer
/// after each attempt that fails, and right away when the context's socket appears.
@Observable
final class DockerConnection {
    enum Status: Equatable {
        case connecting
        case connected
        /// Nothing answers at the context's endpoint.
        case notRunning
        case problem(DockerProblem)
    }

    /// The pace of reading and reconnecting; tests make it quicker.
    struct Timing {
        /// After an event, before reading, so the rest of a burst comes in first.
        var readDelay: Duration
        /// A read still going after this gives up as timed out.
        var readTimeout: Duration
        /// The first wait before reconnecting, doubling with each attempt that fails.
        var firstRetryDelay: Duration
        var maximumRetryDelay: Duration
        /// An events stream open this long counts as healthy: when it ends, reconnecting starts over at the first
        /// delay.
        var healthyAfter: Duration
        /// Between one stats answer and the next request.
        var statsInterval: Duration

        static let standard = Timing(
            readDelay: .milliseconds(250), readTimeout: .seconds(15), firstRetryDelay: .seconds(2),
            maximumRetryDelay: .seconds(120), healthyAfter: .seconds(60), statsInterval: .seconds(5))
    }

    let choice: DockerContextChoice
    private(set) var status = Status.connecting {
        didSet {
            guard status != oldValue else { return }
            Log.docker.notice(
                "Docker \(self.logName, privacy: .public): \(String(describing: self.status), privacy: .public)")
            if (status == .connected) != (oldValue == .connected) { restartStats() }
        }
    }
    /// The containers as last read: kept while stopped and while Docker isn't running.
    private(set) var snapshot: DockerSnapshot?
    /// CPU and memory by container ID, while ``samplesStats``.
    private(set) var stats: [String: DockerStats] = [:]
    /// Reads CPU and memory every few seconds, for the details panel.
    var samplesStats = false {
        didSet {
            guard samplesStats != oldValue else { return }
            restartStats()
        }
    }
    /// The context's socket, watched while Docker isn't running so it reconnects as soon as it starts.
    @ObservationIgnored var socketURL: URL? {
        didSet {
            guard socketURL != oldValue, socketWatcher != nil else { return }
            watchSocket()
        }
    }

    /// Reconnect attempts that failed in a row.
    @ObservationIgnored private(set) var consecutiveFailures = 0
    /// How long the next reconnect waits.
    var retryDelay: Duration {
        UsageRefresh.retryDelay(
            interval: timing.firstRetryDelay, consecutiveFailures: max(0, consecutiveFailures - 1),
            maximum: timing.maximumRetryDelay)
    }

    @ObservationIgnored private let transport: DockerService.Transport
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var stream: DockerEventStream?
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private let reload = CoalescedReload()
    @ObservationIgnored private let watchdog = DelayedTask()
    @ObservationIgnored private let reconnect = PacedTask()
    @ObservationIgnored private let sampling = PacedTask()
    @ObservationIgnored private var socketWatcher: FileWatcher?
    /// Since when reads have succeeded with the events stream open.
    @ObservationIgnored private var healthySince: ContinuousClock.Instant?

    init(choice: DockerContextChoice, transport: DockerService.Transport, timing: Timing = .standard) {
        self.choice = choice
        self.transport = transport
        self.timing = timing
    }

    private var logName: String {
        switch choice {
        case .current: "(current context)"
        case .named(let name): "context \(name)"
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        if status != .connected { status = .connecting }
        connect()
        restartStats()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        reload.cancel()
        watchdog.cancel()
        reconnect.stop()
        sampling.stop()
        if !stats.isEmpty { stats = [:] }
        socketWatcher = nil
        closeStream()
    }

    /// Connects again now, forgetting past failures.
    func refreshNow() {
        guard isRunning else { return }
        consecutiveFailures = 0
        if case .problem = status { status = .connecting }
        restart()
    }

    /// Drops the events stream and the read under way, and connects again now.
    func restart() {
        guard isRunning else { return }
        reload.cancel()
        watchdog.cancel()
        closeStream()
        connect()
    }

    // MARK: Events

    private func connect() {
        reconnect.stop()
        socketWatcher = nil
        healthySince = nil
        // Events from a second ago on are replayed, so one that happens while the containers are read isn't missed.
        let since = Date.now.addingTimeInterval(-1)
        do {
            let stream = try transport.stream(DockerCLI.arguments(DockerCLI.events(since: since), context: choice))
            self.stream = stream
            reading = Task { [weak self] in
                for await _ in stream.lines {
                    guard let self, !Task.isCancelled else { return }
                    requestRead(after: timing.readDelay)
                }
                guard !Task.isCancelled else { return }
                self?.streamEnded()
            }
        } catch {
            Log.docker.error("Couldn't start docker events: \(String(describing: error), privacy: .public)")
            fail(.failed("Couldn't run docker."))
            return
        }
        requestRead(after: .zero)
    }

    private func closeStream() {
        reading?.cancel()
        reading = nil
        stream?.terminate()
        stream = nil
    }

    /// `docker events` exited: Docker quit, the Mac slept, or the VM paused on an older Docker Desktop.
    private func streamEnded() {
        guard isRunning else { return }
        Log.docker.info("docker events ended for \(self.logName, privacy: .public)")
        reading = nil
        stream = nil
        // A read under way says why; otherwise one more read does, as the next attempt.
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard isRunning, !reconnect.isRunning else { return }
        if let healthySince, ContinuousClock.now - healthySince >= timing.healthyAfter { consecutiveFailures = 0 }
        healthySince = nil
        consecutiveFailures += 1
        let delay = retryDelay
        Log.docker.info("Reconnecting to Docker in \(String(describing: delay), privacy: .public)")
        reconnect.start(after: delay) { [weak self] in
            self?.reload.cancel()
            self?.closeStream()
            self?.connect()
            return nil
        }
        if status != .connected { watchSocket() }
    }

    /// While Docker isn't running, its socket appearing means it started: reconnect then, not at the next attempt.
    private func watchSocket() {
        socketWatcher = nil
        guard let socketURL else { return }
        let path = socketURL.path(percentEncoded: false)
        // Nil when the folder doesn't exist yet: the backoff alone reconnects then.
        socketWatcher = FileWatcher(
            file: socketURL,
            onMainActor: { [weak self] in
                guard let self, isRunning, status != .connected, reconnect.isRunning,
                    FileManager.default.fileExists(atPath: path)
                else { return }
                Log.docker.info("Docker's socket appeared; reconnecting")
                restart()
            })
    }

    // MARK: Reading

    private func requestRead(after delay: Duration) {
        reload.request(after: delay) { [weak self] in await self?.read() }
    }

    private func read() async {
        watchdog.schedule(after: timing.readTimeout) { [weak self] in self?.timedOut() }
        let result = await readContainers()
        guard isRunning, !Task.isCancelled else { return }
        watchdog.cancel()
        switch result {
        case .success(let containers):
            if snapshot?.containers != containers {
                snapshot = DockerSnapshot(containers: containers, fetchedAt: .now)
                Log.docker.debug("Docker \(self.logName, privacy: .public): \(containers.count) containers")
            }
            status = .connected
            if stream != nil, healthySince == nil { healthySince = .now }
            // A stream that ended while reading reconnects now that the read says Docker answers.
            if stream == nil { scheduleReconnect() }
        case .failure(let problem):
            fail(problem)
        }
    }

    /// `ps -aq`, then one `inspect` of every ID. `nil` when cancelled.
    private func readContainers() async -> Result<[DockerContainer], DockerProblem> {
        guard let list = await transport.run(DockerCLI.arguments(DockerCLI.listIDs, context: choice)) else {
            return .failure(.failed("Couldn't run docker."))
        }
        guard !Task.isCancelled else { return .success([]) }
        guard list.status == 0 else {
            return .failure(DockerProblem(message: String(decoding: list.error, as: UTF8.self)))
        }
        let ids = String(decoding: list.output, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.isEmpty }
        guard !ids.isEmpty else { return .success([]) }
        guard let inspect = await transport.run(DockerCLI.arguments(DockerCLI.inspect(ids), context: choice)) else {
            return .failure(.failed("Couldn't run docker."))
        }
        guard !Task.isCancelled else { return .success([]) }
        // A container removed between the two calls fails inspect, which still prints every other one.
        if inspect.status != 0, inspect.output.isEmpty {
            let message = String(decoding: inspect.error, as: UTF8.self)
            guard message.contains("No such") else { return .failure(DockerProblem(message: message)) }
        }
        return .success(await Self.containers(in: inspect.output))
    }

    @concurrent
    private static func containers(in output: Data) async -> [DockerContainer] {
        DockerContainer.list(inspectOutput: output)
    }

    private func timedOut() {
        guard isRunning else { return }
        Log.docker.notice("Docker \(self.logName, privacy: .public) didn't answer in time")
        reload.cancel()
        fail(.timedOut)
    }

    private func fail(_ problem: DockerProblem) {
        status = problem == .notRunning ? .notRunning : .problem(problem)
        closeStream()
        scheduleReconnect()
    }

    // MARK: Stats

    private func restartStats() {
        sampling.stop()
        guard isRunning, samplesStats, status == .connected else {
            if !stats.isEmpty { stats = [:] }
            return
        }
        sampling.start(
            after: .zero, tolerance: { _ in .seconds(1) },
            run: { [weak self] in
                guard let self else { return nil }
                await sampleStats()
                return timing.statsInterval
            })
    }

    private func sampleStats() async {
        let ids = (snapshot?.containers ?? []).filter { $0.state == .running }.map(\.id)
        guard !ids.isEmpty else {
            if !stats.isEmpty { stats = [:] }
            return
        }
        let result = await transport.run(DockerCLI.arguments(DockerCLI.stats(ids), context: choice))
        guard isRunning, samplesStats, !Task.isCancelled, let result, !result.output.isEmpty else { return }
        let sampled = await Self.stats(in: result.output)
        guard isRunning, samplesStats, !Task.isCancelled else { return }
        if sampled != stats { stats = sampled }
    }

    @concurrent
    private static func stats(in output: Data) async -> [String: DockerStats] {
        DockerStats.list(output: output)
    }
}
