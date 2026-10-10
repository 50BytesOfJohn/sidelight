import Foundation
import Observation
import SidelightCore
import os

/// Whose sign-in a Railway connection uses.
enum RailwaySignInSource: Hashable {
    /// The Railway CLI's, read from its configuration file.
    case cli
    /// The token saved in Sidelight's keychain item.
    case token
}

/// Railway accounts' projects, services and bills for the Railway widgets on screen, from Railway's public API.
///
/// There's a connection per sign-in the widgets use (the Railway CLI's or a saved token). Each asks once for every
/// widget using it, only for what their blocks show, and as often as ``RailwayPacing`` allows. Nothing runs, and
/// the CLI's sign-in isn't read, until a Railway widget is added.
@Observable
final class RailwayService {
    let cli = RailwayConnection(source: .cli)
    let token = RailwayConnection(source: .token)

    /// Whether the Railway CLI is installed where Sidelight looks for it.
    private(set) var cliExecutable: URL?
    /// Whether the Railway CLI is signed in, as of the last look at its configuration.
    private(set) var cliIsSignedIn = false
    /// Whether a token is saved in the keychain.
    private(set) var hasToken = false

    /// What the widgets need, by whose sign-in they use. Set from the configuration.
    var needs: [RailwayAccountChoice: RailwayNeeds] = [:] {
        didSet {
            guard needs != oldValue else { return }
            apply()
        }
    }

    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var savedToken: String?
    @ObservationIgnored private var hasLookedForToken = false

    init() {
        cli.credentials = { [weak self] in await self?.cliCredentials() ?? .failure(.cliNotSignedIn) }
        token.credentials = { [weak self] in await self?.tokenCredentials() ?? .failure(.noToken) }
    }

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        apply()
    }

    func stop() {
        isEnabled = false
        cli.needs = nil
        token.needs = nil
    }

    /// The connection a widget with `choice` shows.
    func connection(for choice: RailwayAccountChoice) -> RailwayConnection {
        switch resolved(choice) {
        case .cli: cli
        case .token: token
        }
    }

    /// Automatic uses the CLI while it's signed in, otherwise a saved token, otherwise asks for the CLI's sign-in.
    func resolved(_ choice: RailwayAccountChoice) -> RailwaySignInSource {
        switch choice {
        case .cli: .cli
        case .token: .token
        case .automatic: cliIsSignedIn || !hasToken ? .cli : .token
        }
    }

    /// Fetches now with every connection in use.
    func refreshNow() {
        lookAround()
        cli.refreshNow()
        token.refreshNow()
    }

    /// Checks `token` with Railway and saves it in the keychain; returns why it wasn't saved.
    func saveToken(_ token: String) async -> RailwayFetchProblem? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .noToken }
        let request = RailwayAPI.request(RailwayAPI.accountQuery, token: token, userAgent: Self.userAgent)
        let check = await RailwayConnection.send(request)
        switch check.map({ RailwayAPI.account(status: $0.status, body: $0.body) }) {
        case .failure(let problem), .success(.failure(let problem)): return problem
        case .success(.success):
            guard await Self.storeToken(token) else { return .refused(message: "Couldn't save to the keychain") }
            savedToken = token
            hasToken = true
            hasLookedForToken = true
            apply()
            self.token.refreshNow()
            return nil
        }
    }

    func removeToken() {
        Task {
            await Self.deleteToken()
            savedToken = nil
            hasToken = false
            apply()
        }
    }

    // MARK: Demand

    private func apply() {
        lookAround()
        guard isEnabled else { return }
        var bySource: [RailwaySignInSource: RailwayNeeds] = [:]
        for (choice, needs) in needs {
            let source = resolved(choice)
            bySource[source] = bySource[source].map { $0.merged(with: needs) } ?? needs
        }
        cli.needs = bySource[.cli]
        token.needs = bySource[.token]
    }

    /// Looks for the CLI and its sign-in, and the saved token: all local and cheap. Done whenever the demand
    /// changes and before each request, so signing in with the CLI is noticed without restarting.
    private func lookAround() {
        guard isEnabled || !needs.isEmpty else { return }
        cliExecutable = ExecutableLocator.find("railway", in: RailwayCLISignIn.executableDirectories)
        let signedIn = (try? Data(contentsOf: RailwayCLISignIn.configFile)).flatMap(RailwayCLISignIn.init) != nil
        if signedIn != cliIsSignedIn { cliIsSignedIn = signedIn }
        if !hasLookedForToken {
            hasLookedForToken = true
            Task {
                savedToken = await Self.readToken()
                hasToken = savedToken != nil
                apply()
            }
        }
    }

    // MARK: Credentials

    @ObservationIgnored private var lastRenewal: Date?
    /// Running the CLI to renew its token is tried at most this often.
    private static let renewalGap: TimeInterval = 5 * 60

    /// The CLI's token, renewed by the CLI itself when it has run out.
    private func cliCredentials() async -> Result<String, RailwayFetchProblem> {
        var signIn = await Self.readCLISignIn()
        cliIsSignedIn = signIn != nil
        guard let current = signIn else { return .failure(.cliNotSignedIn) }
        if current.needsRenewal(at: .now), let executable = cliExecutable,
            lastRenewal.map({ Date.now.timeIntervalSince($0) > Self.renewalGap }) ?? true
        {
            lastRenewal = .now
            Log.railway.info("Asking the Railway CLI to renew its sign-in")
            await Self.runCLI(executable, arguments: RailwayCLISignIn.renewalArguments)
            signIn = await Self.readCLISignIn()
        }
        guard let signIn else { return .failure(.cliNotSignedIn) }
        return signIn.isUsable(at: .now) ? .success(signIn.accessToken) : .failure(.cliSignInExpired)
    }

    private func tokenCredentials() async -> Result<String, RailwayFetchProblem> {
        if !hasLookedForToken {
            hasLookedForToken = true
            savedToken = await Self.readToken()
            hasToken = savedToken != nil
        }
        return savedToken.map { .success($0) } ?? .failure(.noToken)
    }

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "Sidelight/\(version)"
    }

    @concurrent
    private static func readCLISignIn() async -> RailwayCLISignIn? {
        (try? Data(contentsOf: RailwayCLISignIn.configFile)).flatMap(RailwayCLISignIn.init)
    }

    /// Runs the CLI, giving up after 30 seconds.
    @concurrent
    private static func runCLI(_ executable: URL, arguments: [String]) async {
        await withTaskGroup { group in
            group.addTask { _ = await ProcessRunner.result(of: executable, arguments: arguments) }
            group.addTask { try? await Task.sleep(for: .seconds(30)) }
            await group.next()
            group.cancelAll()
        }
    }

    @concurrent
    private static func readToken() async -> String? { RailwayTokenStore.read() }

    @concurrent
    private static func storeToken(_ token: String) async -> Bool { RailwayTokenStore.save(token) }

    @concurrent
    private static func deleteToken() async { RailwayTokenStore.delete() }
}

/// Railway as seen with one sign-in: the account's workspaces, what the widgets using it need, and the last answer.
@Observable
final class RailwayConnection {
    /// After failed fetches, the wait doubles up to this.
    static let maximumRetryDelay: TimeInterval = 60 * 60
    /// "Refresh now", and newly needed data, wait at least this long after the last request.
    static let minimumGap: TimeInterval = 10
    /// The account's workspaces are asked for again this often.
    static let accountInterval: TimeInterval = 60 * 60

    let source: RailwaySignInSource

    /// The last status fetched; kept through later failures, which ``problem`` reports.
    private(set) var snapshot: Railway.Snapshot?
    /// Why the last fetch failed; `nil` after a success.
    private(set) var problem: RailwayFetchProblem?
    /// The account's workspaces, for choosing one.
    private(set) var account: RailwayAPI.Account?
    /// Commits of the latest deploys, by deploy ID.
    private(set) var commits: [String: Railway.Commit] = [:]
    /// CPU, memory and recent deploys of the services Service blocks show.
    private(set) var details: [RailwayServiceTarget: Railway.ServiceDetail] = [:]
    private(set) var rateLimit: RailwayRateLimit?
    private(set) var isFetching = false
    /// When the last request finished, successful or not.
    private(set) var lastAttempt: Date?
    /// When the next request goes out, while one is scheduled.
    private(set) var nextFetch: Date?

    /// What the widgets using this sign-in need; `nil` while none does, which stops fetching.
    var needs: RailwayNeeds? {
        didSet {
            guard needs != oldValue else { return }
            if needs == nil {
                task?.cancel()
                task = nil
                nextFetch = nil
                return
            }
            // Something newly shown is fetched soon; anything else keeps the schedule.
            let gained = oldValue.map { old in needs.map { !$0.isCovered(by: old) } ?? false } ?? true
            restart(soon: gained)
        }
    }

    @ObservationIgnored var credentials: () async -> Result<String, RailwayFetchProblem> = { .failure(.notSignedIn) }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var accountFetchedAt: Date?
    @ObservationIgnored private var usageFetchedAt: Date?
    @ObservationIgnored private var incidentsFetchedAt: Date?
    @ObservationIgnored private var consecutiveFailures = 0

    init(source: RailwaySignInSource) {
        self.source = source
    }

    /// Whether the last good data is old: a fetch has failed since, or it's missed more than two refreshes.
    func isStale(at now: Date) -> Bool {
        guard let snapshot else { return false }
        if problem != nil { return true }
        let interval = needs?.refreshMinutes.map { TimeInterval($0) * 60 } ?? RailwayPacing.idleInterval
        return now.timeIntervalSince(snapshot.fetchedAt) > 2 * interval + 60
    }

    func refreshNow() {
        guard needs != nil, !isFetching else { return }
        restart(soon: true)
    }

    private func restart(soon: Bool) {
        task?.cancel()
        let sinceLast = lastAttempt.map { Date.now.timeIntervalSince($0) } ?? .infinity
        let delay =
            soon
            ? max(0, Self.minimumGap - sinceLast)
            : max(0, (nextFetch ?? .now).timeIntervalSinceNow)
        schedule(after: delay)
    }

    private func schedule(after delay: TimeInterval) {
        nextFetch = Date.now.addingTimeInterval(delay)
        task = Task { [weak self] in
            var delay = delay
            while true {
                if delay > 0 {
                    do { try await Task.sleep(for: .seconds(delay), tolerance: .seconds(min(delay / 10, 30))) } catch {
                        return
                    }
                }
                guard let self, !Task.isCancelled else { return }
                delay = await fetch()
                guard !Task.isCancelled else { return }
                nextFetch = Date.now.addingTimeInterval(delay)
            }
        }
    }

    // MARK: Fetching

    /// Asks Railway for everything the widgets need, and returns how long to wait before asking again.
    private func fetch() async -> TimeInterval {
        guard let needs else { return RailwayPacing.idleInterval }
        isFetching = true
        defer {
            isFetching = false
            lastAttempt = .now
        }
        let result = await fetchStatus(needs)
        guard !Task.isCancelled else { return RailwayPacing.idleInterval }
        switch result {
        case .success(var snapshot):
            if needs.incidents { snapshot.incidents = await incidents(snapshot.incidents ?? self.snapshot?.incidents) }
            self.snapshot = snapshot
            problem = nil
            consecutiveFailures = 0
            if needs.commits { await fetchCommits(for: snapshot) }
            await fetchMissingDetails(needs, in: snapshot)
            return RailwayPacing.interval(
                refreshMinutes: needs.refreshMinutes, isDeploying: snapshot.isDeploying, rateLimit: rateLimit,
                now: .now)
        case .failure(let failure):
            if failure != problem { Log.railway.notice("Can't fetch from Railway: \(String(describing: failure))") }
            problem = failure
            consecutiveFailures += 1
            if case .rateLimited(let retryAfter?) = failure { return max(retryAfter, RailwayPacing.idleInterval) }
            // Signing in happens on this Mac, so look again soon; it costs nothing until it works.
            if failure == .cliNotSignedIn || failure == .noToken || failure == .cliSignInExpired { return 60 }
            let base = needs.refreshMinutes.map { TimeInterval($0) * 60 } ?? RailwayPacing.idleInterval
            let backoff = base * Double(1 << min(consecutiveFailures, 10))
            return min(backoff, max(base, Self.maximumRetryDelay))
        }
    }

    private func fetchStatus(_ needs: RailwayNeeds) async -> Result<Railway.Snapshot, RailwayFetchProblem> {
        let token: String
        switch await credentials() {
        case .success(let value): token = value
        case .failure(let problem): return .failure(problem)
        }
        if account == nil || accountFetchedAt.map({ Date.now.timeIntervalSince($0) > Self.accountInterval }) ?? true
            || needs.workspaceIDs.contains(where: { id in id.map { !knows($0) } ?? false })
        {
            switch await send(RailwayAPI.accountQuery, token: token).flatMap({
                RailwayAPI.account(status: $0.status, body: $0.body)
            }) {
            case .success(let fetched):
                account = fetched
                accountFetchedAt = .now
            case .failure(let problem):
                return .failure(problem)
            }
        }
        guard let account else { return .failure(.unreadable) }
        // The chosen workspaces the account has, and its first one for widgets that chose none.
        var ids: [String] = []
        for id in needs.workspaceIDs.map({ $0 ?? account.workspaces.first?.id }) {
            if let id, knows(id), !ids.contains(id) { ids.append(id) }
        }
        guard !ids.isEmpty else { return .failure(.noWorkspace) }

        let usageInterval = max(
            RailwayPacing.usageInterval, TimeInterval(needs.refreshMinutes ?? 0) * 60)
        let includesUsage =
            needs.usage
            && (usageFetchedAt.map { Date.now.timeIntervalSince($0) >= usageInterval - 5 } ?? true
                || snapshot?.workspaces.contains { ids.contains($0.id) && $0.bill == nil } ?? true)
        // Services shown in detail ride along, in environments the last answer named. One that answer couldn't
        // place (the first time) is asked for right after this one.
        let targets = needs.services.sorted { "\($0)" < "\($1)" }
        let placed = targets.compactMap { target in snapshot?.detailRequest(for: target).map { (target, $0) } }
        let document = RailwayAPI.statusQuery(
            workspaceCount: ids.count, includesUsage: includesUsage, detailCount: placed.count)
        let variables = RailwayAPI.statusVariables(workspaceIDs: ids, details: placed.map(\.1), now: .now)
        let result = await send(document, variables: variables, token: token).flatMap {
            RailwayAPI.status(status: $0.status, body: $0.body, workspaceCount: ids.count, detailCount: placed.count)
        }
        if case .success(let status) = result {
            var details = self.details.filter { needs.services.contains($0.key) }
            for ((target, _), detail) in zip(placed, status.details) { details[target] = detail }
            self.details = details
        }
        return result.flatMap { status in
            guard !status.workspaces.isEmpty else { return .failure(.notAuthorized) }
            if includesUsage { usageFetchedAt = .now }
            // Bills not asked for this time carry over from the last answer.
            let workspaces = status.workspaces.map { workspace in
                var workspace = workspace
                if workspace.bill == nil, needs.usage {
                    workspace.bill = snapshot?.workspace(id: workspace.id)?.bill
                }
                return workspace
            }
            return .success(
                Railway.Snapshot(
                    userName: account.name, workspaces: workspaces, incidents: snapshot?.incidents, fetchedAt: .now))
        }
    }

    /// Details for services the last status request couldn't place, now that `snapshot` can.
    private func fetchMissingDetails(_ needs: RailwayNeeds, in snapshot: Railway.Snapshot) async {
        let missing = needs.services.filter { details[$0] == nil }.sorted { "\($0)" < "\($1)" }
        let placed = missing.compactMap { target in snapshot.detailRequest(for: target).map { (target, $0) } }
        guard !placed.isEmpty, case .success(let token) = await credentials() else { return }
        let document = RailwayAPI.statusQuery(workspaceCount: 0, includesUsage: false, detailCount: placed.count)
        let variables = RailwayAPI.statusVariables(workspaceIDs: [], details: placed.map(\.1), now: .now)
        let result = await send(document, variables: variables, token: token).flatMap {
            RailwayAPI.status(status: $0.status, body: $0.body, workspaceCount: 0, detailCount: placed.count)
        }
        guard case .success(let status) = result else { return }
        for ((target, _), detail) in zip(placed, status.details) { details[target] = detail }
    }

    private func knows(_ workspaceID: String) -> Bool {
        account?.workspaces.contains { $0.id == workspaceID } ?? false
    }

    /// Commits for latest deploys not seen before, a batch at a time. Deploys that are gone are forgotten.
    private func fetchCommits(for snapshot: Railway.Snapshot) async {
        let ids = snapshot.deploymentIDs
        commits = commits.filter { ids.contains($0.key) }
        let missing = Array(ids.subtracting(commits.keys).sorted().prefix(RailwayAPI.commitBatchSize))
        guard !missing.isEmpty, case .success(let token) = await credentials() else { return }
        let document = RailwayAPI.commitsQuery(count: missing.count)
        let variables = Dictionary(uniqueKeysWithValues: missing.enumerated().map { ("d\($0.offset)", $0.element) })
        let result = await send(document, variables: variables, token: token).flatMap {
            RailwayAPI.commits(status: $0.status, body: $0.body)
        }
        if case .success(let fetched) = result {
            commits.merge(fetched) { _, new in new }
            // Deploys without a readable commit aren't asked about again.
            for id in missing where commits[id] == nil { commits[id] = Railway.Commit() }
        }
    }

    /// Railway's incidents, asked for at most every ten minutes; `previous` in between or when the page can't be read.
    private func incidents(_ previous: [Railway.Incident]?) async -> [Railway.Incident]? {
        if let incidentsFetchedAt, Date.now.timeIntervalSince(incidentsFetchedAt) < RailwayPacing.incidentsInterval {
            return previous
        }
        incidentsFetchedAt = .now
        var request = URLRequest(url: RailwayAPI.statusPage, timeoutInterval: 20)
        request.setValue(RailwayService.userAgent, forHTTPHeaderField: "User-Agent")
        guard case .success(let response) = await Self.send(request), response.status == 200 else { return previous }
        return RailwayStatusPage.incidents(from: response.body) ?? previous
    }

    private func send(
        _ document: String, variables: [String: String] = [:], token: String
    ) async -> Result<Response, RailwayFetchProblem> {
        let request = RailwayAPI.request(
            document, variables: variables, token: token, userAgent: RailwayService.userAgent)
        let result = await Self.send(request)
        if case .success(let response) = result {
            rateLimit = RailwayRateLimit(headers: response.headers, now: .now)
            if response.status == 429 { return .failure(.rateLimited(retryAfter: rateLimit?.retryAfter)) }
        }
        return result
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    private nonisolated static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    @concurrent
    static func send(_ request: URLRequest) async -> Result<Response, RailwayFetchProblem> {
        do {
            let (body, response) = try await urlSession.data(for: request)
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            return .success(Response(status: http?.statusCode ?? 0, headers: headers, body: body))
        } catch {
            return .failure(.unreachable)
        }
    }
}
