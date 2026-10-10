import Foundation
import Observation
import SidelightCore
import os

/// A Cursor account's included usage for the billing cycle, fetched from Cursor every ``refreshInterval`` once a
/// Cursor widget opts in.
///
/// Cursor keeps no usage on this Mac, and has no public usage API for individual plans, so this asks the endpoint
/// behind Cursor's web dashboard (``CursorUsageAPI``), signed in as the Cursor app or, failing that, the Cursor CLI
/// is. Without the opt-in, or while no Cursor widget is visible, nothing runs at all.
@Observable
final class CursorService {
    /// After failed fetches, the wait doubles up to this.
    static let maximumRetryDelay: Duration = .seconds(60 * 60)
    /// "Refresh now" waits at least this long after the last fetch, so it can't hammer Cursor.
    static let minimumManualRefreshGap: TimeInterval = 30

    /// The last usage fetched; kept through later failures, which ``problem`` reports.
    private(set) var usage: CursorUsage?
    /// Why the last fetch failed; `nil` after a success.
    private(set) var problem: CursorFetchProblem?
    /// Whose sign-in the last successful fetch used.
    private(set) var signInSource: CursorSignIn.Source?
    private(set) var isFetching = false
    /// When the last fetch finished, successful or not.
    private(set) var lastAttempt: Date?

    /// How often to fetch; `nil` not to. Set from the widgets' settings.
    var refreshInterval: Duration? {
        didSet {
            guard refreshInterval != oldValue else { return }
            if refreshInterval == nil {
                usage = nil
                problem = nil
                signInSource = nil
                lastAttempt = nil
                consecutiveFailures = 0
            }
            restartRefreshing()
        }
    }

    /// Whether the last good data is old: a fetch has failed since, or it's missed more than two refreshes.
    func isStale(at now: Date) -> Bool {
        guard let usage else { return false }
        if problem != nil { return true }
        guard let refreshInterval else { return false }
        return now.timeIntervalSince(usage.fetchedAt) > 2 * Double(refreshInterval.components.seconds) + 60
    }

    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var consecutiveFailures = 0

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        restartRefreshing()
    }

    func stop() {
        isEnabled = false
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Fetches now, then carries on at the interval. Ignored right after another fetch.
    func refreshNow() {
        guard !isFetching else { return }
        if let lastAttempt, Date.now.timeIntervalSince(lastAttempt) < Self.minimumManualRefreshGap { return }
        restartRefreshing(immediately: true)
    }

    private func restartRefreshing(immediately: Bool = false) {
        refreshTask?.cancel()
        refreshTask = nil
        guard isEnabled, let interval = refreshInterval else { return }
        // Hiding and showing the widget, or opening the Widgets window, restarts this: don't ask sooner than the
        // interval (or the backoff) because of it.
        let wait = UsageRefresh.retryDelay(
            interval: interval, consecutiveFailures: consecutiveFailures, maximum: Self.maximumRetryDelay)
        var delay = immediately ? .zero : lastAttempt.map { wait - .seconds(Date.now.timeIntervalSince($0)) } ?? .zero
        refreshTask = Task { [weak self] in
            while true {
                if delay > .zero {
                    do { try await Task.sleep(for: delay, tolerance: .seconds(30)) } catch { return }
                }
                guard let self, !Task.isCancelled else { return }
                delay = await fetch(interval: interval)
            }
        }
    }

    /// Returns how long to wait before the next fetch.
    private func fetch(interval: Duration) async -> Duration {
        isFetching = true
        defer { isFetching = false }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let result = await Self.fetchUsage(userAgent: "Sidelight/\(version)")
        guard isEnabled, refreshInterval != nil, !Task.isCancelled else { return interval }
        lastAttempt = .now
        switch result {
        case .success(let fetched):
            usage = fetched.usage
            signInSource = fetched.source
            problem = nil
            consecutiveFailures = 0
        case .failure(let failure):
            if failure != problem {
                Log.cursor.notice("Can't fetch Cursor usage: \(String(describing: failure))")
            }
            problem = failure
            consecutiveFailures += 1
        }
        return UsageRefresh.retryDelay(
            interval: interval, consecutiveFailures: consecutiveFailures, maximum: Self.maximumRetryDelay)
    }

    private nonisolated static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private struct Fetched: Sendable {
        var usage: CursorUsage
        var source: CursorSignIn.Source
    }

    /// Tries the Cursor app's sign-in, then the CLI's. Each is read afresh for this one request, since Cursor renews
    /// them, and is never stored or logged. An expired one is skipped rather than refreshed, and one Cursor turns
    /// down makes way for the next.
    @concurrent
    private static func fetchUsage(userAgent: String) async -> Result<Fetched, CursorFetchProblem> {
        var problem = CursorFetchProblem.notSignedIn
        for source in [CursorSignIn.Source.app, .cli] {
            guard let signIn = await readSignIn(from: source) else { continue }
            guard !signIn.isExpired(at: .now) else {
                if problem == .notSignedIn { problem = .signInExpired }
                continue
            }
            let request = CursorUsageAPI.request(signIn: signIn, userAgent: userAgent)
            let result: Result<CursorUsage, CursorFetchProblem>
            do {
                let (body, response) = try await urlSession.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                result = CursorUsageAPI.result(status: status, body: body, receivedAt: .now)
            } catch {
                result = .failure(.unreachable)
            }
            switch result {
            case .success(let usage): return .success(Fetched(usage: usage, source: source))
            case .failure(let failure) where failure.isSignInRejection: problem = failure
            case .failure(let failure): return .failure(failure)
            }
        }
        return .failure(problem)
    }

    private nonisolated static func readSignIn(from source: CursorSignIn.Source) async -> CursorSignIn? {
        switch source {
        case .app:
            return EditorStateDatabase.value(forKey: CursorSignIn.appTokenKey, in: CursorSignIn.appStateDatabase)
                .flatMap { CursorSignIn(accessToken: $0, source: .app) }
        case .cli:
            // Through the `security` tool, so macOS's "Always Allow" covers the item even after the CLI rewrites it.
            let keychain = await ProcessRunner.output(
                of: URL(filePath: "/usr/bin/security"),
                arguments: [
                    "find-generic-password", "-s", CursorSignIn.cliKeychainService, "-a",
                    CursorSignIn.cliKeychainAccount, "-w",
                ]
            )
            return keychain.flatMap { String(data: $0, encoding: .utf8) }
                .flatMap { CursorSignIn(accessToken: $0, source: .cli) }
        }
    }
}
