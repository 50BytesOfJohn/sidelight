import Foundation
import Observation
import SidelightCore
import os

/// Codex rate limits and token usage.
///
/// Primary source is `codex app-server` (JSON-RPC over stdio, read-only methods only). If it's not installed,
/// exits, or doesn't report rate limits within ``appServerTimeout``, the newest session rollout file is read
/// instead and re-read whenever Codex writes to it.
@Observable
final class CodexService: DataService {
    static let executableName = "codex"
    static let appServerTimeout: Duration = .seconds(15)
    static let refreshInterval = CodexState.refreshInterval
    static let appServerRetryDelay: Duration = .seconds(300)
    /// "Refresh now" waits at least this long after the last request.
    static let minimumManualRefreshGap: TimeInterval = 10

    private(set) var state = CodexState()

    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var appServer: ChildProcess?
    @ObservationIgnored private var session = CodexAppServerSession()
    @ObservationIgnored private var readingTask: Task<Void, Never>?
    @ObservationIgnored private let refreshes = RepeatingTask()
    @ObservationIgnored private let watchdog = DelayedTask()
    @ObservationIgnored private let retry = DelayedTask()
    @ObservationIgnored private var rolloutLoadTask: Task<Void, Never>?
    @ObservationIgnored private var rolloutWatcher: FileEventStream?
    @ObservationIgnored private var lastRequest: Date?

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        state.source = .starting
        startAppServer()
    }

    func stop() {
        isEnabled = false
        for task in [readingTask, rolloutLoadTask] { task?.cancel() }
        refreshes.stop()
        watchdog.cancel()
        retry.cancel()
        readingTask = nil
        rolloutLoadTask = nil
        appServer?.terminate()
        appServer = nil
        rolloutWatcher = nil
        state.source = .off
    }

    /// Asks the app-server again, or starts it if it isn't running. Ignored right after another request.
    func refreshNow() {
        guard isEnabled else { return }
        if let lastRequest, Date.now.timeIntervalSince(lastRequest) < Self.minimumManualRefreshGap { return }
        if appServer != nil {
            requestUpdates()
        } else {
            retry.cancel()
            startAppServer()
        }
    }

    // MARK: App server

    private func startAppServer() {
        guard isEnabled, appServer == nil else { return }
        guard let executable = ExecutableLocator.find(Self.executableName) else {
            Log.codex.info("codex is not installed; reading rollout files instead")
            startRolloutFallback()
            return
        }
        let process: ChildProcess
        do {
            process = try ChildProcess(executable: executable, arguments: ["app-server"])
        } catch {
            Log.codex.error("Can't start codex app-server: \(error)")
            startRolloutFallback()
            return
        }

        appServer = process
        session = CodexAppServerSession()
        CodexAppServerSession.handshake(clientName: "sidelight", clientVersion: AppInfo.version).forEach(process.send)
        requestUpdates()

        // Left over from a server that exited: the retry that started this one, and the old server's watchdog.
        readingTask?.cancel()
        watchdog.cancel()
        retry.cancel()
        readingTask = Task { [weak self] in
            for await line in process.lines {
                // Delivered as `stop()` ran: a newer server's session would read it as its own answer.
                guard let self, !Task.isCancelled, appServer === process else { return }
                handleAppServerLine(line)
            }
            self?.appServerDidExit(process)
        }
        watchdog.schedule(after: Self.appServerTimeout) { [weak self] in
            guard let self, state.source != .appServer else { return }
            Log.codex.notice("codex app-server sent no rate limits in time; reading rollout files")
            startRolloutFallback()
        }
        refreshes.schedule(every: Self.refreshInterval, tolerance: .seconds(5)) { [weak self] in
            self?.requestUpdates()
        }
    }

    private func requestUpdates() {
        guard let appServer else { return }
        lastRequest = .now
        for method in CodexAppServerSession.Method.allCases {
            appServer.send(session.request(method))
        }
    }

    private func handleAppServerLine(_ line: Data) {
        guard let message = session.decode(line) else { return }
        switch message {
        case .account(let account):
            state.account = account
            // Without a ChatGPT sign-in there are no plan limits to wait for, so the session logs (possibly
            // another account's) mustn't stand in for them.
            if !account.hasPlanLimits { didReceiveFromAppServer() }
        case .rateLimits(let reading):
            state.rateLimits = reading.rateLimits
            state.resetCredits = reading.resetCredits
            state.ordinaryUsageAllowed = reading.ordinaryUsageAllowed
            state.limitsCapturedAt = .now
            state.sessionTokens = nil
            state.problem = nil
            didReceiveFromAppServer()
        case .rateLimitsUpdated(let update):
            state.rateLimits = (state.rateLimits ?? CodexRateLimits()).merging(update)
            state.limitsCapturedAt = .now
            didReceiveFromAppServer()
        case .usage(let usage):
            state.usage = usage
        case .failed(.readRateLimits, let message):
            Log.codex.notice("codex app-server can't read rate limits: \(message, privacy: .public)")
            state.problem = message
        case .failed(let method, let message):
            Log.codex.debug(
                "codex app-server failed \(method.rawValue, privacy: .public): \(message, privacy: .public)")
        case .accountUpdated(let plan):
            if let plan { state.rateLimits?.planType = plan }
            // The sign-in changed: everything else may have too.
            requestUpdates()
        }
    }

    private func didReceiveFromAppServer() {
        state.source = .appServer
        watchdog.cancel()
        rolloutWatcher = nil
    }

    private func appServerDidExit(_ process: ChildProcess) {
        guard appServer === process else { return }
        appServer = nil
        refreshes.stop()
        watchdog.cancel()
        guard isEnabled else { return }
        Log.codex.notice("codex app-server exited; retrying later")
        // What it said last stays on screen, no longer live, until the session logs have something newer.
        state.source = .starting
        startRolloutFallback()
        retry.schedule(after: Self.appServerRetryDelay) { [weak self] in self?.startAppServer() }
    }

    // MARK: Rollout fallback

    private func startRolloutFallback() {
        reloadRollout()
        guard rolloutWatcher == nil else { return }
        rolloutWatcher = FileEventStream(directory: CodexRollout.defaultSessionsDirectory, latency: 2) { [weak self] in
            self?.reloadRollout()
        }
    }

    private func reloadRollout() {
        guard isEnabled, state.source != .appServer else { return }
        rolloutLoadTask?.cancel()
        rolloutLoadTask = Task { [weak self] in
            let snapshot = await Self.loadRolloutSnapshot()
            guard !Task.isCancelled, let self, isEnabled, state.source != .appServer else { return }
            guard let snapshot else {
                if state.rateLimits == nil { state.source = .unavailable }
                return
            }
            // Keep a newer reading from an app-server that has since exited.
            if let shown = state.limitsCapturedAt, let logged = snapshot.capturedAt, logged < shown { return }
            state.rateLimits = snapshot.rateLimits
            state.limitsCapturedAt = snapshot.capturedAt
            state.ordinaryUsageAllowed = nil
            state.resetCredits = nil
            state.sessionTokens = snapshot.sessionTokens
            state.source = .rolloutFile
        }
    }

    /// Directory scan and file I/O, kept off the main actor.
    @concurrent
    private static func loadRolloutSnapshot() async -> CodexRolloutSnapshot? {
        CodexRollout.latestSnapshot()
    }
}
