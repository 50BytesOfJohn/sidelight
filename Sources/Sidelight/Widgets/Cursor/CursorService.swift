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
final class CursorService: DataService {
    /// The last usage fetched; kept through later failures, which ``problem`` reports.
    private(set) var usage: CursorUsage?
    /// Why the last fetch failed; `nil` after a success.
    private(set) var problem: CursorFetchProblem?
    /// Whose sign-in the last successful fetch used.
    private(set) var signInSource: CursorSignIn.Source?

    /// "Refresh now" waits at least 30 seconds after the last fetch, so it can't hammer Cursor.
    private let schedule = FetchSchedule(minimumManualGap: .seconds(30), tolerance: .seconds(30))

    var isFetching: Bool { schedule.isFetching }
    /// When the last fetch finished, successful or not.
    var lastAttempt: Date? { schedule.lastAttempt }

    /// How often to fetch; `nil` not to. Set from the widgets' settings.
    var refreshInterval: Duration? {
        get { schedule.interval }
        set {
            guard newValue != schedule.interval else { return }
            if newValue == nil {
                usage = nil
                problem = nil
                signInSource = nil
            }
            schedule.interval = newValue
        }
    }

    /// Whether the last good data is old: a fetch has failed since, or it's missed more than two refreshes.
    func isStale(at now: Date) -> Bool {
        guard let usage else { return false }
        if problem != nil { return true }
        guard let refreshInterval else { return false }
        return now.timeIntervalSince(usage.fetchedAt) > 2 * refreshInterval.timeInterval + 60
    }

    func start() {
        schedule.start { [weak self] in await self?.fetch() }
    }

    func stop() {
        schedule.stop()
    }

    /// Fetches now, then carries on at the interval. Ignored right after another fetch.
    func refreshNow() {
        schedule.refreshNow()
    }

    private func fetch() async -> FetchSchedule.Outcome? {
        let result = await Self.fetchUsage(userAgent: AppInfo.userAgent)
        guard !Task.isCancelled else { return nil }
        switch result {
        case .success(let fetched):
            usage = fetched.usage
            signInSource = fetched.source
            problem = nil
            return .succeeded
        case .failure(let failure):
            if failure != problem {
                Log.cursor.notice("Can't fetch Cursor usage: \(String(describing: failure))")
            }
            problem = failure
            return .failed
        }
    }

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
                let response = try await HTTP.send(request)
                result = CursorUsageAPI.result(status: response.status, body: response.body, receivedAt: .now)
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
            let keychain = await Keychain.genericPassword(
                service: CursorSignIn.cliKeychainService, account: CursorSignIn.cliKeychainAccount)
            return keychain.flatMap { String(data: $0, encoding: .utf8) }
                .flatMap { CursorSignIn(accessToken: $0, source: .cli) }
        }
    }
}
