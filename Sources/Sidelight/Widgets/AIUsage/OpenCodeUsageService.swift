import Foundation
import Observation
import SidelightCore
import os

/// OpenCode Console workspaces' usage limits, fetched every ``refreshInterval`` for each OpenCode account an AI Usage
/// widget shows and opted in to fetching: OpenCode Go's 5-hour, weekly and monthly allowance, and the workspace's
/// budgets.
///
/// OpenCode keeps no usage on this Mac, so this asks OpenCode's Console the way OpenCode itself does
/// (``OpenCodeUsageAPI``), with OpenCode's own sign-in or a key added in Settings. OpenCode's sign-in is read from its
/// database for each fetch, never stored, refreshed or logged; the database is also read, without asking anyone,
/// whenever the service starts, to tell whether OpenCode is signed in.
@Observable
final class OpenCodeUsageService: DataService {
    /// What one account last fetched.
    struct AccountUsage: Equatable {
        /// Kept through later failures, which ``problem`` reports.
        var usage: OpenCodeUsage?
        /// Why the last fetch failed; `nil` after a success.
        var problem: OpenCodeFetchProblem?
    }

    /// Each account fetched, while a widget wants it.
    private(set) var accounts: [AccountID: AccountUsage] = [:]

    /// The accounts to fetch, each with how often in minutes. Set from the widgets' settings.
    var demand: [AccountID: Int] = [:] {
        didSet {
            guard demand != oldValue else { return }
            for id in accounts.keys where demand[id] == nil { accounts[id] = nil }
            let interval = demand.values.min().map { Duration.seconds($0 * 60) }
            // A new account is asked for right away, rather than at the next refresh.
            let hasNewAccount = !Set(demand.keys).isSubset(of: oldValue.keys)
            if hasNewAccount { schedule.reset() }
            if interval == schedule.interval {
                if hasNewAccount { schedule.refreshNow() }
            } else {
                schedule.interval = interval
            }
        }
    }

    var isFetching: Bool { schedule.isFetching }

    private var userAgent: String { AppInfo.userAgent }

    @ObservationIgnored private let access: AccountAccess
    @ObservationIgnored private let database: URL?
    /// "Refresh now" waits at least 30 seconds after the last fetch, so it can't hammer OpenCode.
    private let schedule = FetchSchedule(minimumManualGap: .seconds(30), tolerance: .seconds(30))
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var lookAround: Task<Void, Never>?
    /// What OpenCode's database said the last time it was read.
    @ObservationIgnored private var lastSignIn: SignInState?

    /// - Parameter database: Where OpenCode keeps its sign-in; `nil` when it keeps none in a file.
    init(accounts: AccountAccess, database: URL? = OpenCodeUsageService.defaultDatabase) {
        access = accounts
        self.database = database
        accounts.observeChanges { [weak self] id in
            // Another key: forget what the old one saw, and ask with the new one.
            guard let self, self.accounts[id] != nil else { return }
            self.accounts[id] = AccountUsage()
            schedule.reset()
            schedule.refreshNow()
        }
    }

    /// Where OpenCode's CLI keeps its database, given the environment Sidelight was started with.
    static var defaultDatabase: URL? {
        let location = OpenCodeSessionIndex.location(
            environment: ProcessInfo.processInfo.environment, home: .homeDirectory)
        return if case .file(let url) = location { url } else { nil }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        schedule.start { [weak self] in await self?.fetch() }
        lookAround = Task { [weak self] in
            guard let database = self?.database else { return }
            let signIn = await Self.readSignIn(database)
            guard !Task.isCancelled else { return }
            self?.note(signIn)
        }
    }

    func stop() {
        isRunning = false
        schedule.stop()
        lookAround?.cancel()
        lookAround = nil
    }

    /// Fetches every account now, then carries on at the interval. Ignored right after another fetch.
    func refreshNow() {
        schedule.refreshNow()
    }

    func usage(of id: AccountID) -> AccountUsage? {
        accounts[id]
    }

    /// Whether `id`'s last good data is old: a fetch has failed since, or it's missed more than two refreshes.
    func isStale(_ id: AccountID, at now: Date) -> Bool {
        guard let account = accounts[id], let usage = account.usage else { return false }
        if account.problem != nil { return true }
        guard let minutes = demand.values.min() else { return false }
        return now.timeIntervalSince(usage.fetchedAt) > 2 * Double(minutes * 60) + 60
    }

    /// Asks OpenCode about Go's usage with `candidate`; returns why the key can't be used. A workspace without Go
    /// still takes the key.
    func checkKey(_ candidate: String) async -> OpenCodeFetchProblem? {
        let credential = OpenCodeCredential.key(candidate)
        guard !credential.token.isEmpty else { return .notSignedIn }
        let answer = await Self.send(OpenCodeUsageAPI.goUsageRequest(credential, userAgent: userAgent))
        guard let answer else { return .unreachable }
        return switch answer.status {
        case 200, 403: nil
        default: .rejected(status: answer.status)
        }
    }

    // MARK: Fetching

    private func fetch() async -> FetchSchedule.Outcome? {
        let ids = demand.keys.sorted()
        guard !ids.isEmpty else { return nil }
        var succeeded = true
        for id in ids {
            let credential = await credential(for: id)
            guard !Task.isCancelled else { return nil }
            let result: Result<OpenCodeUsage, OpenCodeFetchProblem>
            switch credential {
            case .success(let credential): result = await Self.fetchUsage(with: credential, userAgent: userAgent)
            case .failure(let problem): result = .failure(problem)
            }
            guard !Task.isCancelled, demand[id] != nil else { continue }
            var account = accounts[id] ?? AccountUsage()
            switch result {
            case .success(let usage):
                account.usage = usage
                account.problem = nil
                access.report(.connected, id)
                if case .success(let credential) = credential { access.reportIdentity(credential.identity, id) }
            case .failure(let problem):
                if problem != account.problem {
                    Log.openCode.notice("Can't fetch OpenCode usage: \(String(describing: problem), privacy: .public)")
                }
                account.problem = problem
                access.report(problem.accountStatus, id)
                succeeded = false
            }
            accounts[id] = account
        }
        return succeeded ? .succeeded : .failed
    }

    /// What to ask OpenCode with for `id`: its key, or OpenCode's own sign-in, read afresh. An expired sign-in is
    /// skipped rather than refreshed: OpenCode renews it the next time it runs.
    private func credential(for id: AccountID) async -> Result<OpenCodeCredential, OpenCodeFetchProblem> {
        guard id == .openCodeCLI else {
            do throws(KeychainUnavailable) {
                guard let key = try await access.secret(id) else { return .failure(.notSignedIn) }
                return .success(.key(key))
            } catch {
                return .failure(.keychainUnavailable)
            }
        }
        guard let database else { return .failure(.notSignedIn) }
        let signIn = await Self.readSignIn(database)
        guard !Task.isCancelled else { return .failure(.notSignedIn) }
        note(signIn)
        switch signIn {
        case .signedIn(let credential) where credential.isExpired(at: .now): return .failure(.signInExpired)
        case .signedIn(let credential): return .success(credential)
        case .signedOut, .notFound: return .failure(.notSignedIn)
        case .unreadable: return .failure(.unreadableSignIn)
        }
    }

    /// Says whether OpenCode is installed and signed in, when that changed; which decides the account widgets
    /// without one of their own use.
    private func note(_ signIn: OpenCodeSignIn) {
        let state = SignInState(signIn)
        guard state != lastSignIn else { return }
        lastSignIn = state
        access.reportAppSignIn(.openCodeCLI, state != .notFound, state == .signedIn)
        if state == .signedOut { access.report(.needsSignIn, .openCodeCLI) }
    }

    /// What OpenCode's database said, without the credential.
    private enum SignInState: Equatable {
        case signedIn, signedOut, notFound, unreadable

        init(_ signIn: OpenCodeSignIn) {
            self =
                switch signIn {
                case .signedIn: .signedIn
                case .signedOut: .signedOut
                case .notFound: .notFound
                case .unreadable: .unreadable
                }
        }
    }

    @concurrent
    private static func readSignIn(_ database: URL) async -> OpenCodeSignIn {
        OpenCodeSignIn.read(database: database)
    }

    /// Asks for Go's allowance and the budgets together.
    @concurrent
    private static func fetchUsage(
        with credential: OpenCodeCredential, userAgent: String
    ) async -> Result<OpenCodeUsage, OpenCodeFetchProblem> {
        async let go = send(OpenCodeUsageAPI.goUsageRequest(credential, userAgent: userAgent))
        async let budgets = send(OpenCodeUsageAPI.budgetsRequest(credential, userAgent: userAgent))
        return OpenCodeUsageAPI.result(go: await go, budgets: await budgets, credential: credential, receivedAt: .now)
    }

    @concurrent
    private static func send(_ request: URLRequest) async -> OpenCodeUsageAPI.Answer? {
        guard let response = try? await HTTP.send(request) else { return nil }
        return OpenCodeUsageAPI.Answer(status: response.status, body: response.body)
    }
}
