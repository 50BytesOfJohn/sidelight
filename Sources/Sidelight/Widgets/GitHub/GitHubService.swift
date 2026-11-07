import Foundation
import Observation
import SidelightCore
import os

/// GitHub for every GitHub widget on screen: for each account a widget uses, the searches, repositories and calendar
/// its blocks show, the inbox, and githubstatus.com. Read-only.
///
/// The default account is the GitHub CLI: Sidelight runs `gh api`, and `gh` signs each request itself, so its token
/// never reaches Sidelight. A token account sends the same requests over HTTP. Each account asks once for every
/// widget using it, in one GraphQL request, and only for what the shown blocks need. Nothing runs, and `gh` isn't
/// looked for, until a GitHub widget is on screen.
@Observable
final class GitHubService: DataService {
    /// The status page is asked at most this often.
    static let statusInterval: Duration = .seconds(10 * 60)

    /// One for each account a widget uses, or used since Sidelight started.
    private(set) var connections: [AccountID: GitHubConnection] = [:]
    /// Where `gh` is installed, if it is.
    private(set) var cliExecutable: URL?
    /// Who `gh` is signed in as on github.com, from its settings; `nil` when signed in to no one.
    private(set) var cliUser: String?
    /// githubstatus.com's incidents, shared by every widget.
    let status = RemoteResource<[GitHub.Incident], GitHubFetchProblem>(manualGap: .seconds(60))

    var cliIsSignedIn: Bool { cliUser != nil }

    /// What the widgets on screen need. Set from the configuration.
    var demand = GitHubDemand() {
        didSet {
            guard demand != oldValue else { return }
            apply()
        }
    }

    @ObservationIgnored private let access: AccountAccess
    @ObservationIgnored private var isEnabled = false

    init(accounts: AccountAccess) {
        access = accounts
        status.fetch = { await GitHubService.fetchStatus(userAgent: AppInfo.userAgent) }
        accounts.observeChanges { [weak self] id in self?.connections[id]?.reset() }
    }

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        apply()
    }

    func stop() {
        isEnabled = false
        apply()
    }

    func connection(_ id: AccountID) -> GitHubConnection? {
        connections[id]
    }

    /// Looks for `gh` again, and fetches everything now, or as soon as allowed.
    func refreshNow() {
        lookAround()
        for connection in connections.values { connection.refreshNow() }
        status.refreshNow()
    }

    /// Asks GitHub who `token` belongs to; returns why it can't be used.
    func checkToken(_ token: String) async -> GitHubFetchProblem? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .noToken }
        let request = GitHubRequest()
        switch await GitHubTransport.token(token).graphQL(request, userAgent: AppInfo.userAgent) {
        case .failure(let problem): return problem
        case .success(let body):
            if case .failure(let problem) = GitHubAPI.response(to: request, body: body) { return problem }
            return nil
        }
    }

    // MARK: Demand

    private func apply() {
        lookAround()
        let needsStatus = isEnabled && demand.accounts.values.contains(where: \.status)
        status.policy = needsStatus ? .every(Self.statusInterval) : nil
        for id in demand.accounts.keys where connections[id] == nil {
            let access = access
            connections[id] = GitHubConnection(
                account: id,
                transport: { [weak self] in await self?.transport(for: id) ?? .failure(.noToken) },
                report: { access.report($0, id) },
                reportIdentity: { access.reportIdentity($0, id) })
        }
        for (id, connection) in connections {
            connection.needs = isEnabled ? demand.accounts[id] : nil
        }
    }

    /// Looks for `gh` and its sign-in: local and cheap. Whether it's signed in decides which account widgets without
    /// one of their own use.
    private func lookAround() {
        guard isEnabled else { return }
        cliExecutable = ExecutableLocator.find("gh", in: GitHubCLI.executableDirectories)
        let hosts = GitHubCLI.configDirectory().appending(path: "hosts.yml", directoryHint: .notDirectory)
        let user = (try? String(contentsOf: hosts, encoding: .utf8)).flatMap(GitHubCLI.signedInUser(hostsYAML:))
        if user != cliUser {
            cliUser = user
            // The next fetch says how it's doing.
            access.report(user == nil ? .needsSignIn : nil, .gitHubCLI)
            if let user, !user.isEmpty { access.reportIdentity(user, .gitHubCLI) }
        }
        access.reportAppSignIn(.gitHubCLI, cliExecutable != nil || user != nil, user != nil && cliExecutable != nil)
    }

    /// How to ask with `id`: through `gh`, or with a token account's token.
    private func transport(for id: AccountID) async -> Result<GitHubTransport, GitHubFetchProblem> {
        guard id != .gitHubCLI else {
            lookAround()
            guard let cliExecutable else { return .failure(.cliNotFound) }
            guard cliIsSignedIn else { return .failure(.cliNotSignedIn) }
            return .success(.cli(cliExecutable))
        }
        do throws(KeychainUnavailable) {
            return try await access.secret(id).map { .success(.token($0)) } ?? .failure(.noToken)
        } catch {
            return .failure(.keychain)
        }
    }

    @concurrent
    private static func fetchStatus(userAgent: String) async -> FetchResult<[GitHub.Incident], GitHubFetchProblem>? {
        var request = URLRequest(url: GitHubAPI.statusPage, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let response = try? await HTTP.send(request) else { return .failure(.unreachable, retry: .backoff) }
        guard !Task.isCancelled else { return nil }
        guard response.status == 200, let incidents = GitHubAPI.incidents(from: response.body) else {
            return .failure(.unreadable, retry: .backoff)
        }
        return .success(incidents)
    }
}

/// What one account's GraphQL request came back with, kept between fetches.
struct GitHubSnapshot {
    var login: String?
    var searches: [GitHubSearch: GitHub.SearchResult] = [:]
    /// By lowercased `owner/name`; `nil` for one GitHub can't find.
    var repositories: [String: GitHub.Repository?] = [:]
    var contributions: GitHub.Contributions?
    var contributionsFetchedAt: Date?
    /// GitHub's messages for parts it couldn't answer.
    var errors: [String] = []

    /// The results of `search`, once fetched.
    func result(_ search: GitHubSearch?) -> GitHub.SearchResult? {
        search.flatMap { searches[$0] }
    }

    /// `nil` before it's fetched, `.some(nil)` when GitHub can't find it.
    func repository(_ name: String) -> GitHub.Repository?? {
        repositories[name.lowercased()]
    }
}

/// GitHub as one account sees it, shared by every widget using it.
@Observable
final class GitHubConnection {
    /// The contribution calendar is asked for again this often: it changes a few times a day.
    static let contributionsInterval: TimeInterval = 30 * 60

    let accountID: AccountID
    let snapshot: RemoteResource<GitHubSnapshot, GitHubFetchProblem>
    let notifications: RemoteResource<[GitHub.Notification], GitHubFetchProblem>
    private(set) var rateLimit: GitHubRateLimit?

    /// What the widgets using this account need; `nil` while none is on screen.
    var needs: GitHubNeeds? {
        didSet {
            guard needs != oldValue else { return }
            apply(previous: oldValue)
        }
    }

    @ObservationIgnored private let makeTransport: () async -> Result<GitHubTransport, GitHubFetchProblem>
    @ObservationIgnored private let report: (AccountStatus?) -> Void
    @ObservationIgnored private let reportIdentity: (String?) -> Void

    init(
        account: AccountID, transport: @escaping () async -> Result<GitHubTransport, GitHubFetchProblem>,
        report: @escaping (AccountStatus?) -> Void, reportIdentity: @escaping (String?) -> Void
    ) {
        accountID = account
        makeTransport = transport
        self.report = report
        self.reportIdentity = reportIdentity
        snapshot = RemoteResource(manualGap: .seconds(10), firstRetryDelay: .seconds(60))
        notifications = RemoteResource(manualGap: .seconds(10), firstRetryDelay: .seconds(60))
        snapshot.fetch = { [weak self] in await self?.fetchSnapshot() }
        notifications.fetch = { [weak self] in await self?.fetchNotifications() }
    }

    func refreshNow() {
        snapshot.refreshNow()
        notifications.refreshNow()
    }

    /// Another token: what the old one saw goes, and the new one asks again.
    func reset() {
        rateLimit = nil
        snapshot.reset()
        notifications.reset()
    }

    private func apply(previous: GitHubNeeds?) {
        guard let needs else {
            snapshot.policy = nil
            notifications.policy = nil
            return
        }
        snapshot.policy = needs.needsGraphQL ? RefreshPolicy(needs.cadence) : nil
        notifications.policy = needs.notifications == nil ? nil : RefreshPolicy(needs.cadence)
        // Something newly shown is fetched soon, rather than at the next refresh.
        if needs.needsGraphQL, let value = snapshot.value, !covers(value, needs) { snapshot.refreshNow() }
        if let query = needs.notifications, let previous = previous?.notifications, query != previous {
            notifications.refreshNow()
        }
    }

    /// Whether `snapshot` answers everything `needs` asks for.
    private func covers(_ snapshot: GitHubSnapshot, _ needs: GitHubNeeds) -> Bool {
        needs.searches.allSatisfy { search, rows in
            guard let result = snapshot.searches[search] else { return false }
            return result.items.count >= min(rows, result.totalCount)
        } && needs.repositories.allSatisfy { snapshot.repositories.keys.contains($0) }
            && (!needs.contributions || snapshot.contributions != nil)
    }

    // MARK: Fetching

    private func fetchSnapshot() async -> FetchResult<GitHubSnapshot, GitHubFetchProblem>? {
        guard let needs else { return nil }
        let transport: GitHubTransport
        switch await makeTransport() {
        case .success(let value): transport = value
        case .failure(let problem): return failed(problem)
        }
        guard !Task.isCancelled else { return nil }
        let previous = snapshot.value
        let calendarIsFresh =
            previous?.contributionsFetchedAt.map { Date.now.timeIntervalSince($0) < Self.contributionsInterval }
            ?? false
        let request = GitHubRequest(
            searches: needs.searches, repositories: needs.repositories,
            contributions: needs.contributions && !calendarIsFresh)
        let answer = await transport.graphQL(request, userAgent: AppInfo.userAgent)
        guard !Task.isCancelled else { return nil }
        let response: GitHubResponse
        switch answer.flatMap({ GitHubAPI.response(to: request, body: $0) }) {
        case .success(let value): response = value
        case .failure(let problem): return failed(problem)
        }
        if let limit = response.rateLimit { rateLimit = limit }
        report(.connected)
        reportIdentity(response.login)
        if !response.errors.isEmpty {
            Log.gitHub.notice("GitHub answered with errors: \(response.errors.joined(separator: "; "))")
        }
        var value = GitHubSnapshot(
            login: response.login, searches: response.searches, repositories: response.repositories,
            errors: response.errors)
        if let contributions = response.contributions {
            value.contributions = contributions
            value.contributionsFetchedAt = .now
        } else if needs.contributions {
            value.contributions = previous?.contributions
            value.contributionsFetchedAt = previous?.contributionsFetchedAt
        }
        return .success(value)
    }

    private func fetchNotifications() async -> FetchResult<[GitHub.Notification], GitHubFetchProblem>? {
        guard let query = needs?.notifications else { return nil }
        let transport: GitHubTransport
        switch await makeTransport() {
        case .success(let value): transport = value
        case .failure(let problem): return .failure(problem, retry: problem.retryAdvice())
        }
        guard !Task.isCancelled else { return nil }
        let answer = await transport.rest(GitHubAPI.notificationsPath(query), userAgent: AppInfo.userAgent)
        guard !Task.isCancelled else { return nil }
        switch answer {
        case .success(let body):
            guard let threads = GitHubAPI.notifications(from: body) else {
                return .failure(.unreadable, retry: .backoff)
            }
            return .success(threads)
        case .failure(let problem):
            return .failure(problem, retry: problem.retryAdvice())
        }
    }

    private func failed(_ problem: GitHubFetchProblem) -> FetchResult<GitHubSnapshot, GitHubFetchProblem> {
        if problem != snapshot.problem { Log.gitHub.notice("Can't fetch from GitHub: \(String(describing: problem))") }
        report(problem.accountStatus)
        return .failure(problem, retry: problem.retryAdvice())
    }
}

/// How requests reach GitHub: through `gh`, signed in as it is, or over HTTP with a token.
nonisolated enum GitHubTransport: Sendable {
    case cli(URL)
    case token(String)

    /// `gh` gets this long to answer.
    static let timeout: Duration = .seconds(30)

    @concurrent
    func graphQL(_ request: GitHubRequest, userAgent: String) async -> Result<Data, GitHubFetchProblem> {
        switch self {
        case .cli(let executable):
            return await Self.run(executable, arguments: GitHubCLI.graphQLArguments(request))
        case .token(let token):
            return await Self.send(GitHubAPI.graphQLRequest(request, token: token, userAgent: userAgent))
        }
    }

    @concurrent
    func rest(_ path: String, userAgent: String) async -> Result<Data, GitHubFetchProblem> {
        switch self {
        case .cli(let executable):
            return await Self.run(executable, arguments: GitHubCLI.restArguments(path: path))
        case .token(let token):
            return await Self.send(GitHubAPI.restRequest(path: path, token: token, userAgent: userAgent))
        }
    }

    private static func send(_ request: URLRequest) async -> Result<Data, GitHubFetchProblem> {
        guard let response = try? await HTTP.send(request) else { return .failure(.unreachable) }
        if let problem = GitHubAPI.problem(
            status: response.status, headers: response.headers, body: response.body, now: .now)
        {
            return .failure(problem)
        }
        return .success(response.body)
    }

    /// Runs `gh`, giving up after ``timeout``.
    private static func run(_ executable: URL, arguments: [String]) async -> Result<Data, GitHubFetchProblem> {
        let result = await withTaskGroup(of: ProcessRunner.Result?.self) { group in
            group.addTask {
                await ProcessRunner.result(of: executable, arguments: arguments, environment: GitHubCLI.environment)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let result else { return .failure(.unreachable) }
        if let problem = GitHubCLI.problem(status: result.status, output: result.output, error: result.error) {
            return .failure(problem)
        }
        return .success(result.output)
    }
}
