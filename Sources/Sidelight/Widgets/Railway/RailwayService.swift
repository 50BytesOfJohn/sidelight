import Foundation
import Observation
import SidelightCore
import os

/// Railway accounts' projects, services and bills for the Railway widgets on screen, from Railway's public API.
///
/// There's a connection per account the widgets use: the Railway CLI's sign-in, or a token account. Each asks once
/// for every widget using it, only for what their blocks show, and as often as ``RailwayPacing`` allows. Nothing
/// runs, and the CLI's sign-in isn't read, until a Railway widget is added.
@Observable
final class RailwayService: DataService {
    /// One for each account a widget uses, or used since Sidelight started.
    private(set) var connections: [AccountID: RailwayConnection] = [:]
    /// Whether the Railway CLI is installed where Sidelight looks for it.
    private(set) var cliExecutable: URL?
    /// Whether the Railway CLI is signed in, as of the last look at its configuration.
    private(set) var cliIsSignedIn = false

    /// What the widgets need, by the account they use. Set from the configuration.
    var needs: [AccountID: RailwayNeeds] = [:] {
        didSet {
            guard needs != oldValue else { return }
            apply()
        }
    }

    @ObservationIgnored private let access: AccountAccess
    @ObservationIgnored private var isEnabled = false

    init(accounts: AccountAccess) {
        access = accounts
        accounts.observeChanges { [weak self] id in
            // Another token: forget what the old one saw, and ask with the new one.
            guard let connection = self?.connections[id] else { return }
            connection.reset()
            connection.refreshNow()
        }
    }

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        apply()
    }

    func stop() {
        isEnabled = false
        for connection in connections.values { connection.needs = nil }
    }

    /// The connection for `id`, once a widget has used that account.
    func connection(_ id: AccountID) -> RailwayConnection? {
        connections[id]
    }

    /// Fetches now with every connection in use.
    func refreshNow() {
        lookAround()
        for connection in connections.values { connection.refreshNow() }
    }

    /// Asks Railway whether `token` can read an account; returns why it can't be used.
    func checkToken(_ token: String) async -> RailwayFetchProblem? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .noToken }
        let request = RailwayAPI.request(RailwayAPI.accountQuery, token: token, userAgent: AppInfo.userAgent)
        switch await RailwayConnection.send(request).map({ RailwayAPI.account(status: $0.status, body: $0.body) }) {
        case .failure(let problem), .success(.failure(let problem)): return problem
        case .success(.success): return nil
        }
    }

    // MARK: Demand

    private func apply() {
        lookAround()
        guard isEnabled else { return }
        for id in needs.keys where connections[id] == nil {
            let connection = RailwayConnection(account: id)
            connection.credentials = { [weak self] in await self?.credentials(for: id) ?? .failure(.notSignedIn) }
            let access = access
            connection.report = { access.report($0, id) }
            connections[id] = connection
        }
        for (id, connection) in connections {
            connection.needs = needs[id]
        }
    }

    /// Looks for the CLI and its sign-in: local and cheap. Done whenever the demand changes and on "Refresh", so
    /// signing in with the CLI is noticed without restarting. Whether it's signed in decides which account widgets
    /// without one of their own use.
    private func lookAround() {
        guard isEnabled else { return }
        cliExecutable = ExecutableLocator.find("railway", in: RailwayCLISignIn.executableDirectories)
        let signedIn = (try? Data(contentsOf: RailwayCLISignIn.configFile)).flatMap(RailwayCLISignIn.init) != nil
        cliSignInChanged(signedIn)
    }

    private func cliSignInChanged(_ signedIn: Bool) {
        if signedIn != cliIsSignedIn { cliIsSignedIn = signedIn }
        access.reportAppSignIn(.railwayCLI, cliExecutable != nil || signedIn, signedIn)
    }

    // MARK: Credentials

    @ObservationIgnored private var lastRenewal: Date?
    /// Running the CLI to renew its token is tried at most this often.
    private static let renewalGap: TimeInterval = 5 * 60

    /// The account's token: the CLI's, or the one saved for a token account.
    private func credentials(for id: AccountID) async -> Result<String, RailwayFetchProblem> {
        guard id != .railwayCLI else { return await cliCredentials() }
        return await access.secret(id).map { .success($0) } ?? .failure(.noToken)
    }

    /// The CLI's token, renewed by the CLI itself when it has run out.
    private func cliCredentials() async -> Result<String, RailwayFetchProblem> {
        var signIn = await Self.readCLISignIn()
        // Widgets without an account of their own may now use a token instead, or the CLI again.
        cliSignInChanged(signIn != nil)
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
}

/// Railway as seen with one account: its workspaces, what the widgets using it need, and the last answer.
@Observable
final class RailwayConnection {
    /// After failed fetches, the wait doubles up to this.
    static let maximumRetryDelay: TimeInterval = 60 * 60
    /// "Refresh now", and newly needed data, wait at least this long after the last request.
    static let minimumGap: TimeInterval = 10
    /// The account's workspaces are asked for again this often.
    static let accountInterval: TimeInterval = 60 * 60

    /// The account it asks with.
    let accountID: AccountID

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
    /// When the next request goes out. Kept while nothing needs fetching, so showing a widget again (or the panels
    /// after hiding them) doesn't ask sooner than the schedule, backoff or Railway's `Retry-After` allows.
    private(set) var nextFetch: Date?

    /// What the widgets using this sign-in need; `nil` while none does, which stops fetching.
    var needs: RailwayNeeds? {
        didSet {
            guard needs != oldValue else { return }
            guard let needs else {
                cancelFetching()
                return
            }
            // Something newly shown is fetched soon; anything else keeps the schedule.
            let gained = lastNeeds.map { !needs.isCovered(by: $0) } ?? true
            lastNeeds = needs
            restart(soon: gained)
        }
    }

    @ObservationIgnored var credentials: () async -> Result<String, RailwayFetchProblem> = { .failure(.notSignedIn) }
    /// Says how the account is doing, after each fetch.
    @ObservationIgnored var report: (AccountStatus?) -> Void = { _ in }
    @ObservationIgnored private let fetching = PacedTask()
    /// What was needed last, including before fetching stopped.
    @ObservationIgnored private var lastNeeds: RailwayNeeds?
    @ObservationIgnored private var accountFetchedAt: Date?
    /// When each workspace's bill was last asked for, whether or not Railway had one to show.
    @ObservationIgnored private var usageFetchedAt: [String: Date] = [:]
    @ObservationIgnored private var incidentsFetchedAt: Date?
    /// Services whose details were asked for on their own, so a failure isn't retried on every refresh: the
    /// regular request carries them from then on.
    @ObservationIgnored private var detailsAskedAlone: Set<RailwayServiceTarget> = []
    /// After a failed commits request, they're left alone until then.
    @ObservationIgnored private var commitsRetryAfter: Date?
    @ObservationIgnored private var consecutiveFailures = 0

    /// Wait this long after commits couldn't be fetched.
    private static let commitsRetryDelay: TimeInterval = 10 * 60

    init(account: AccountID) {
        accountID = account
    }

    /// Forgets everything the sign-in saw, for a different sign-in.
    func reset() {
        snapshot = nil
        problem = nil
        account = nil
        commits = [:]
        details = [:]
        accountFetchedAt = nil
        usageFetchedAt = [:]
        detailsAskedAlone = []
        commitsRetryAfter = nil
        consecutiveFailures = 0
    }

    func refreshNow() {
        guard needs != nil, !isFetching else { return }
        restart(soon: true)
    }

    private func cancelFetching() {
        fetching.stop()
        isFetching = false
    }

    private func restart(soon: Bool) {
        cancelFetching()
        let sinceLast = lastAttempt.map { Date.now.timeIntervalSince($0) } ?? .infinity
        let delay =
            soon
            ? max(0, Self.minimumGap - sinceLast)
            : max(0, (nextFetch ?? .now).timeIntervalSinceNow)
        schedule(after: delay)
    }

    private func schedule(after delay: TimeInterval) {
        nextFetch = Date.now.addingTimeInterval(delay)
        fetching.start(
            after: .seconds(delay), tolerance: { min($0 / 10, .seconds(30)) },
            run: { [weak self] in
                guard let self else { return nil }
                let delay = await fetch()
                guard !Task.isCancelled else { return nil }
                nextFetch = Date.now.addingTimeInterval(delay)
                return .seconds(delay)
            })
    }

    // MARK: Fetching

    /// Asks Railway for everything the widgets need, and returns how long to wait before asking again.
    private func fetch() async -> TimeInterval {
        guard let needs else { return RailwayPacing.idleInterval }
        isFetching = true
        defer {
            // A cancelled fetch's replacement, if any, owns these now.
            if !Task.isCancelled {
                isFetching = false
                lastAttempt = .now
            }
        }
        let result = await fetchStatus(needs)
        guard !Task.isCancelled else { return RailwayPacing.idleInterval }
        switch result {
        case .success(var snapshot):
            if needs.incidents { snapshot.incidents = await incidents(snapshot.incidents ?? self.snapshot?.incidents) }
            // A newer request replaced this one while it waited: its answer would be older.
            guard !Task.isCancelled else { return RailwayPacing.idleInterval }
            self.snapshot = snapshot
            problem = nil
            consecutiveFailures = 0
            report(.connected)
            if needs.commits { await fetchCommits(for: snapshot, environments: needs.environmentNames) }
            await fetchMissingDetails(needs, in: snapshot)
            return RailwayPacing.interval(
                refreshMinutes: needs.refreshMinutes, isDeploying: snapshot.isDeploying, rateLimit: rateLimit,
                now: .now)
        case .failure(let failure):
            if failure != problem { Log.railway.notice("Can't fetch from Railway: \(String(describing: failure))") }
            problem = failure
            consecutiveFailures += 1
            report(failure.accountStatus)
            if case .rateLimited(let retryAfter?) = failure { return max(retryAfter, RailwayPacing.idleInterval) }
            // Signing in happens on this Mac, so look again soon; it costs nothing until it works.
            if failure == .cliNotSignedIn || failure == .noToken || failure == .cliSignInExpired { return 60 }
            let base = needs.refreshMinutes.map { TimeInterval($0) * 60 } ?? RailwayPacing.idleInterval
            return UsageRefresh.retryDelay(
                interval: .seconds(base), consecutiveFailures: consecutiveFailures,
                maximum: .seconds(Self.maximumRetryDelay)
            ).timeInterval
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
            let fetched = await send(RailwayAPI.accountQuery, token: token).flatMap {
                RailwayAPI.account(status: $0.status, body: $0.body)
            }
            guard !Task.isCancelled else { return .failure(.unreachable) }
            switch fetched {
            case .success(let fetched):
                account = fetched
                accountFetchedAt = .now
            case .failure(let problem):
                return .failure(problem)
            }
        }
        guard let account else { return .failure(.unreadable) }
        // The account's first workspace for widgets that chose none, then the chosen ones the account has.
        let first = account.workspaces.first?.id
        let chosen = needs.workspaceIDs.compactMap(\.self).filter { knows($0) && $0 != first }.sorted()
        let ids = (needs.workspaceIDs.contains(nil) ? [first].compactMap(\.self) : []) + chosen
        guard !ids.isEmpty else { return .failure(.noWorkspace) }

        let usageInterval = max(RailwayPacing.usageInterval, TimeInterval(needs.refreshMinutes ?? 0) * 60)
        let includesUsage =
            needs.usage
            && ids.contains { id in
                usageFetchedAt[id].map { Date.now.timeIntervalSince($0) >= usageInterval - 5 } ?? true
            }
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
        guard !Task.isCancelled else { return .failure(.unreachable) }
        if case .success(let status) = result {
            var details = self.details.filter { needs.services.contains($0.key) }
            // A service Railway had nothing on is known to have nothing, rather than still loading.
            for ((target, _), detail) in zip(placed, status.details) {
                details[target] = detail ?? Railway.ServiceDetail()
            }
            self.details = details
            detailsAskedAlone.formIntersection(needs.services)
        }
        return result.flatMap { status in
            guard !status.workspaces.isEmpty else { return .failure(.notAuthorized) }
            if includesUsage { for id in ids { usageFetchedAt[id] = .now } }
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
                    userName: account.name, workspaces: workspaces, firstWorkspaceID: first,
                    incidents: snapshot?.incidents, fetchedAt: .now))
        }
    }

    /// Details for services the last status request couldn't place, now that `snapshot` can. Each is asked for on
    /// its own once; after that it rides along with the status.
    private func fetchMissingDetails(_ needs: RailwayNeeds, in snapshot: Railway.Snapshot) async {
        let missing = needs.services.filter { details[$0] == nil && !detailsAskedAlone.contains($0) }
            .sorted { "\($0)" < "\($1)" }
        let placed = missing.compactMap { target in snapshot.detailRequest(for: target).map { (target, $0) } }
        guard !placed.isEmpty, case .success(let token) = await credentials() else { return }
        detailsAskedAlone.formUnion(placed.map(\.0))
        let document = RailwayAPI.statusQuery(workspaceCount: 0, includesUsage: false, detailCount: placed.count)
        let variables = RailwayAPI.statusVariables(workspaceIDs: [], details: placed.map(\.1), now: .now)
        let result = await send(document, variables: variables, token: token).flatMap {
            RailwayAPI.status(status: $0.status, body: $0.body, workspaceCount: 0, detailCount: placed.count)
        }
        guard case .success(let status) = result, !Task.isCancelled else { return }
        for ((target, _), detail) in zip(placed, status.details) { details[target] = detail ?? Railway.ServiceDetail() }
    }

    private func knows(_ workspaceID: String) -> Bool {
        account?.workspaces.contains { $0.id == workspaceID } ?? false
    }

    /// Commits for latest deploys not seen before in the environments widgets show, a batch at a time. Deploys
    /// that are gone are forgotten.
    private func fetchCommits(for snapshot: Railway.Snapshot, environments: Set<String?>) async {
        let ids = snapshot.deploymentIDs(inEnvironmentsNamed: environments)
        commits = commits.filter { ids.contains($0.key) }
        if let commitsRetryAfter, commitsRetryAfter > .now { return }
        let missing = Array(ids.subtracting(commits.keys).sorted().prefix(RailwayAPI.commitBatchSize))
        guard !missing.isEmpty, case .success(let token) = await credentials() else { return }
        let document = RailwayAPI.commitsQuery(count: missing.count)
        let variables = Dictionary(uniqueKeysWithValues: missing.enumerated().map { ("d\($0.offset)", $0.element) })
        let result = await send(document, variables: variables, token: token).flatMap {
            RailwayAPI.commits(status: $0.status, body: $0.body)
        }
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let fetched):
            commits.merge(fetched) { _, new in new }
            // Deploys without a readable commit aren't asked about again.
            for id in missing where commits[id] == nil { commits[id] = Railway.Commit() }
            commitsRetryAfter = nil
        case .failure:
            commitsRetryAfter = .now.addingTimeInterval(Self.commitsRetryDelay)
        }
    }

    /// Railway's incidents, asked for at most every ten minutes; `previous` in between or when the page can't be read.
    private func incidents(_ previous: [Railway.Incident]?) async -> [Railway.Incident]? {
        if let incidentsFetchedAt, Date.now.timeIntervalSince(incidentsFetchedAt) < RailwayPacing.incidentsInterval {
            return previous
        }
        incidentsFetchedAt = .now
        var request = URLRequest(url: RailwayAPI.statusPage, timeoutInterval: 20)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        guard case .success(let response) = await Self.send(request), response.status == 200 else { return previous }
        return RailwayStatusPage.incidents(from: response.body) ?? previous
    }

    private func send(
        _ document: String, variables: [String: String] = [:], token: String
    ) async -> Result<HTTP.Response, RailwayFetchProblem> {
        let request = RailwayAPI.request(
            document, variables: variables, token: token, userAgent: AppInfo.userAgent)
        let result = await Self.send(request)
        if case .success(let response) = result {
            rateLimit = RailwayRateLimit(headers: response.headers, now: .now)
            if response.status == 429 { return .failure(.rateLimited(retryAfter: rateLimit?.retryAfter)) }
        }
        return result
    }

    static func send(_ request: URLRequest) async -> Result<HTTP.Response, RailwayFetchProblem> {
        do {
            return .success(try await HTTP.send(request))
        } catch {
            return .failure(.unreachable)
        }
    }
}

extension RailwayFetchProblem {
    /// How the account is doing, when it's this.
    var accountStatus: AccountStatus {
        switch self {
        case .notSignedIn, .cliNotSignedIn, .noToken: .needsSignIn
        case .cliSignInExpired, .rejected: .expired
        default: .failed(title)
        }
    }
}
