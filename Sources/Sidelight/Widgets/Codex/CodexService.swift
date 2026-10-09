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
final class CodexService {
    enum Source: Equatable {
        case off
        case starting
        case appServer
        case rolloutFile
        case unavailable

        var title: String {
            switch self {
            case .off: "off"
            case .starting: "starting…"
            case .appServer: "app-server"
            case .rolloutFile: "rollout file"
            case .unavailable: "unavailable"
            }
        }
    }

    static let executableName = "codex"
    static let appServerTimeout: Duration = .seconds(15)
    static let refreshInterval: Duration = .seconds(60)
    static let appServerRetryDelay: Duration = .seconds(300)
    static let sparklineDays = 14

    private(set) var source: Source = .off
    private(set) var fiveHourWindow: RateLimitWindow?
    private(set) var weeklyWindow: RateLimitWindow?
    private(set) var plan: String?
    private(set) var resetCredits: Int?
    private(set) var lifetimeTokens: Int64?
    private(set) var todayTokens: Int64?
    /// Tokens of the latest session; only known from rollout files.
    private(set) var sessionTokens: Int64?
    /// Tokens per day for the last ``sparklineDays`` days, oldest first.
    private(set) var dailyTokens: [Int64] = []

    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var appServer: ChildProcess?
    @ObservationIgnored private var session = CodexAppServerSession()
    @ObservationIgnored private var readingTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var rolloutLoadTask: Task<Void, Never>?
    @ObservationIgnored private var rolloutWatcher: FileEventStream?

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        source = .starting
        startAppServer()
    }

    func stop() {
        isEnabled = false
        for task in [readingTask, refreshTask, watchdogTask, retryTask, rolloutLoadTask] { task?.cancel() }
        readingTask = nil
        refreshTask = nil
        watchdogTask = nil
        retryTask = nil
        rolloutLoadTask = nil
        appServer?.terminate()
        appServer = nil
        rolloutWatcher = nil
        source = .off
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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        CodexAppServerSession.handshake(clientName: "sidelight", clientVersion: version).forEach(process.send)
        requestUpdates()

        readingTask = Task { [weak self] in
            for await line in process.lines {
                self?.handleAppServerLine(line)
            }
            self?.appServerDidExit(process)
        }
        watchdogTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.appServerTimeout) } catch { return }
            guard let self, source != .appServer else { return }
            Log.codex.notice("codex app-server sent no rate limits in time; reading rollout files")
            startRolloutFallback()
        }
        refreshTask = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: Self.refreshInterval, tolerance: .seconds(5)) } catch { return }
                self?.requestUpdates()
            }
        }
    }

    private func requestUpdates() {
        guard let appServer else { return }
        for method in CodexAppServerSession.Method.allCases {
            appServer.send(session.request(method))
        }
    }

    private func handleAppServerLine(_ line: Data) {
        guard let message = session.decode(line) else { return }
        switch message {
        case .rateLimits(let rateLimits, let resetCredits):
            apply(rateLimits)
            self.resetCredits = resetCredits
            didReceiveFromAppServer()
        case .rateLimitsUpdated(let rateLimits):
            apply(rateLimits)
            didReceiveFromAppServer()
        case .usage(let usage):
            let now = Date.now
            if let lifetime = usage.lifetimeTokens { lifetimeTokens = lifetime }
            todayTokens = usage.tokens(on: now)
            dailyTokens = usage.dailyTotals(endingOn: now, days: Self.sparklineDays)
        case .planUpdated(let plan):
            self.plan = plan
        }
    }

    private func didReceiveFromAppServer() {
        source = .appServer
        watchdogTask?.cancel()
        rolloutWatcher = nil
    }

    private func appServerDidExit(_ process: ChildProcess) {
        guard appServer === process else { return }
        appServer = nil
        refreshTask?.cancel()
        guard isEnabled else { return }
        Log.codex.notice("codex app-server exited; retrying later")
        startRolloutFallback()
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.appServerRetryDelay) } catch { return }
            self?.startAppServer()
        }
    }

    // MARK: Rollout fallback

    private func startRolloutFallback() {
        reloadRollout()
        guard rolloutWatcher == nil else { return }
        rolloutWatcher = FileEventStream(directory: CodexRollout.defaultSessionsDirectory, latency: 2, queue: .main) {
            [weak self] in
            MainActor.assumeIsolated { self?.reloadRollout() }
        }
    }

    private func reloadRollout() {
        guard isEnabled, source != .appServer else { return }
        rolloutLoadTask?.cancel()
        rolloutLoadTask = Task { [weak self] in
            let snapshot = await Self.loadRolloutSnapshot()
            guard !Task.isCancelled, let self, isEnabled, source != .appServer else { return }
            guard let snapshot else {
                source = .unavailable
                return
            }
            apply(snapshot.rateLimits)
            sessionTokens = snapshot.sessionTokens
            source = .rolloutFile
        }
    }

    /// Directory scan and file I/O, kept off the main actor.
    @concurrent
    private static func loadRolloutSnapshot() async -> CodexRolloutSnapshot? {
        CodexRollout.latestSnapshot()
    }

    private func apply(_ rateLimits: CodexRateLimits) {
        fiveHourWindow = rateLimits.primary
        weeklyWindow = rateLimits.secondary
        if let planType = rateLimits.planType { plan = planType }
    }
}
