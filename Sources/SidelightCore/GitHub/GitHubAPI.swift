import Foundation

/// Why GitHub couldn't be asked, or its answer couldn't be used.
public enum GitHubFetchProblem: Error, Hashable, Sendable {
    /// `gh` isn't installed where Sidelight looks.
    case cliNotFound
    /// `gh` is installed but signed in to no account on github.com.
    case cliNotSignedIn
    /// A token account without a token saved.
    case noToken
    case keychain
    /// GitHub turned the token down: it expired or was revoked.
    case rejected
    /// GitHub accepted the token but won't show this to it, such as an organization's SSO asking to authorize it.
    case notPermitted(String?)
    case rateLimited(until: Date?)
    case unreachable
    case unreadable
    /// `gh` failed for another reason, which it said.
    case failed(String)

    public var title: String {
        switch self {
        case .cliNotFound: "GitHub CLI not found"
        case .cliNotSignedIn: "GitHub CLI not signed in"
        case .noToken: "No token saved"
        case .keychain: "Keychain unavailable"
        case .rejected: "GitHub rejected the sign-in"
        case .notPermitted: "Not allowed"
        case .rateLimited: "Rate limited"
        case .unreachable: "Can't reach GitHub"
        case .unreadable: "Unexpected answer"
        case .failed: "GitHub CLI failed"
        }
    }

    public var advice: String {
        switch self {
        case .cliNotFound: "Install it with brew install gh, then run gh auth login. Or add a token in Accounts."
        case .cliNotSignedIn: "Run gh auth login in a terminal, or add a token in Accounts."
        case .noToken: "Add the token again in Settings, under Accounts."
        case .keychain: "Unlock your keychain, then try again."
        case .rejected: "Run gh auth login again, or replace the token in Accounts."
        case .notPermitted(let message): message ?? "The token can't read this. Check its scopes and SSO."
        case .rateLimited(let until):
            until.map { "GitHub asks to wait until \($0.formatted(date: .omitted, time: .shortened))." }
                ?? "GitHub asks to wait a while."
        case .unreachable: "Check the connection. Sidelight tries again on its own."
        case .unreadable: "GitHub answered in a way Sidelight doesn't understand."
        case .failed(let message): message
        }
    }

    /// Only signing in again, or another token, fixes it.
    public var needsSignIn: Bool {
        switch self {
        case .cliNotSignedIn, .noToken, .rejected: true
        default: false
        }
    }

    public var accountStatus: AccountStatus {
        switch self {
        case .cliNotSignedIn, .noToken, .cliNotFound: .needsSignIn
        case .rejected: .expired
        default: .failed(title)
        }
    }

    /// When to try again on its own.
    public func retryAdvice() -> RetryAdvice {
        switch self {
        case .rateLimited(let until): until.map(RetryAdvice.notBefore) ?? .backoff
        case .rejected, .notPermitted: .onRequest
        case .cliNotFound, .cliNotSignedIn, .noToken, .keychain, .unreachable, .unreadable, .failed: .backoff
        }
    }
}

/// How much of the account's GraphQL allowance is left.
public struct GitHubRateLimit: Hashable, Sendable {
    public var remaining: Int
    public var limit: Int
    public var resetAt: Date?

    public init(remaining: Int, limit: Int, resetAt: Date? = nil) {
        self.remaining = remaining
        self.limit = limit
        self.resetAt = resetAt
    }
}

/// One GraphQL request for everything the widgets need: searches, repositories and the contribution calendar.
public struct GitHubRequest: Equatable, Sendable {
    /// Each search with how many results to ask for, in a stable order.
    public var searches: [(search: GitHubSearch, first: Int)]
    /// `owner/name`, lowercased.
    public var repositories: [String]
    public var contributions: Bool

    public init(searches: [GitHubSearch: Int] = [:], repositories: Set<String> = [], contributions: Bool = false) {
        self.searches = searches.sorted { $0.key.query < $1.key.query }.map { ($0.key, max(1, min($0.value, 50))) }
        self.repositories = repositories.sorted()
        self.contributions = contributions
    }

    public static func == (lhs: GitHubRequest, rhs: GitHubRequest) -> Bool {
        lhs.searches.map(\.search) == rhs.searches.map(\.search)
            && lhs.searches.map(\.first)
                == rhs.searches.map(\.first)
            && lhs.repositories == rhs.repositories
            && lhs.contributions == rhs.contributions
    }

    /// The GraphQL document. Values come as variables, so nothing typed into a filter can change the query.
    public var document: String {
        var declarations: [String] = []
        var fields = [
            "viewer { login }",
            "rateLimit { remaining limit resetAt }",
        ]
        for (index, entry) in searches.enumerated() {
            declarations.append("$s\(index): String!")
            let node = entry.search.kind == .pullRequest ? GitHubAPI.pullRequestFields : GitHubAPI.issueFields
            fields.append(
                "s\(index): search(query: $s\(index), type: ISSUE, first: \(entry.first)) { issueCount nodes { \(node) } }"
            )
        }
        for index in repositories.indices {
            declarations += ["$r\(index)o: String!", "$r\(index)n: String!"]
            fields.append(
                "r\(index): repository(owner: $r\(index)o, name: $r\(index)n) { \(GitHubAPI.repositoryFields) }")
        }
        if contributions { fields.append("c: viewer { \(GitHubAPI.contributionFields) }") }
        let header = declarations.isEmpty ? "query" : "query(\(declarations.joined(separator: ", ")))"
        return "\(header) { \(fields.joined(separator: " ")) }"
    }

    /// The document's variables, by name.
    public var variables: [String: String] {
        var variables: [String: String] = [:]
        for (index, entry) in searches.enumerated() { variables["s\(index)"] = entry.search.query }
        for (index, name) in repositories.enumerated() {
            let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
            variables["r\(index)o"] = parts.first ?? ""
            variables["r\(index)n"] = parts.count > 1 ? parts[1] : ""
        }
        return variables
    }
}

/// What GitHub answered one ``GitHubRequest`` with. A part it couldn't answer (a repository that's gone) is missing,
/// and the rest is still there.
public struct GitHubResponse: Sendable {
    public var login: String?
    public var rateLimit: GitHubRateLimit?
    public var searches: [GitHubSearch: GitHub.SearchResult] = [:]
    /// By lowercased `owner/name`; `nil` for one GitHub can't find, or that the account can't see.
    public var repositories: [String: GitHub.Repository?] = [:]
    public var contributions: GitHub.Contributions?
    /// GitHub's messages for the parts it couldn't answer.
    public var errors: [String] = []

    public init() {}
}

public enum GitHubAPI {
    public static let graphQLEndpoint = URL(string: "https://api.github.com/graphql")!
    public static let restEndpoint = URL(string: "https://api.github.com")!
    public static let statusPage = URL(string: "https://www.githubstatus.com/api/v2/summary.json")!
    public static let statusWebsite = URL(string: "https://www.githubstatus.com")!
    public static let notificationsWebsite = URL(string: "https://github.com/notifications")!
    /// Where to create a token for a token account.
    public static let tokenWebsite = URL(
        string: "https://github.com/settings/tokens/new?scopes=repo,read:org,notifications&description=Sidelight")!

    static let pullRequestFields =
        "... on PullRequest { number title url isDraft createdAt updatedAt author { login } "
        + "repository { nameWithOwner } reviewDecision mergeable headRefName additions deletions "
        + "comments { totalCount } commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } }"
    static let issueFields =
        "... on Issue { number title url createdAt updatedAt author { login } repository { nameWithOwner } "
        + "comments { totalCount } labels(first: 3) { nodes { name color } } }"
    static let repositoryFields =
        "nameWithOwner url isPrivate stargazerCount pullRequests(states: OPEN) { totalCount } "
        + "issues(states: OPEN) { totalCount } defaultBranchRef { name target { ... on Commit { messageHeadline "
        + "committedDate statusCheckRollup { state } } } } latestRelease { tagName publishedAt url }"
    static let contributionFields =
        "contributionsCollection { contributionCalendar { totalContributions weeks { contributionDays { date "
        + "contributionCount contributionLevel } } } }"

    /// The request's body, as GitHub's GraphQL endpoint takes it.
    public static func body(for request: GitHubRequest) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["query": request.document, "variables": request.variables]))
            ?? Data()
    }

    /// A GraphQL request with a token account's token.
    public static func graphQLRequest(_ request: GitHubRequest, token: String, userAgent: String) -> URLRequest {
        var urlRequest = URLRequest(url: graphQLEndpoint, timeoutInterval: 30)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body(for: request)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return urlRequest
    }

    /// The REST path for the inbox: unread threads only, newest first.
    public static func notificationsPath(_ query: GitHubNotificationQuery) -> String {
        "notifications?per_page=50&participating=\(query.participatingOnly)"
    }

    /// A REST request with a token account's token.
    public static func restRequest(path: String, token: String, userAgent: String) -> URLRequest {
        var urlRequest = URLRequest(url: URL(string: path, relativeTo: restEndpoint)!, timeoutInterval: 30)
        urlRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return urlRequest
    }

    // MARK: Answers

    /// What an HTTP status says went wrong; `nil` for success.
    public static func problem(status: Int, headers: [String: String], body: Data, now: Date) -> GitHubFetchProblem? {
        switch status {
        case 200..<300: return nil
        case 401: return .rejected
        case 403, 429:
            let header = { (name: String) in
                headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
            }
            let text = String(decoding: body, as: UTF8.self)
            if status == 429 || header("x-ratelimit-remaining") == "0"
                || text.localizedCaseInsensitiveContains("rate limit")
            {
                let reset = header("x-ratelimit-reset").flatMap(TimeInterval.init).map(
                    Date.init(timeIntervalSince1970:))
                return .rateLimited(until: RetryAfter.date(in: headers, now: now) ?? reset)
            }
            return .notPermitted(message(in: body))
        case 500...: return .unreachable
        default: return .failed(message(in: body) ?? "GitHub answered \(status).")
        }
    }

    /// GitHub's `message` in an error body.
    private static func message(in body: Data) -> String? {
        struct Body: Decodable { var message: String? }
        return (try? JSONDecoder().decode(Body.self, from: body))?.message
    }

    /// Reads GitHub's answer to `request`. Answers with errors still count when they carry data: one repository that
    /// can't be found doesn't hide the rest.
    public static func response(to request: GitHubRequest, body: Data) -> Result<GitHubResponse, GitHubFetchProblem> {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: body) else { return .failure(.unreadable) }
        let messages = payload.errors?.compactMap(\.message) ?? []
        guard let data = payload.data else {
            if payload.errors?.contains(where: { $0.type == "RATE_LIMITED" }) == true {
                return .failure(.rateLimited(until: nil))
            }
            return .failure(messages.first.map(GitHubFetchProblem.failed) ?? .unreadable)
        }
        var response = GitHubResponse()
        response.login = data.viewer?.login
        response.rateLimit = data.rateLimit
        response.errors = messages
        for (index, entry) in request.searches.enumerated() {
            if let result = data.searches["s\(index)"] { response.searches[entry.search] = result }
        }
        for (index, name) in request.repositories.enumerated() {
            response.repositories[name] = .some(data.repositories["r\(index)"])
        }
        response.contributions = data.contributions
        return .success(response)
    }

    /// Reads the inbox: one page of unread threads.
    public static func notifications(from body: Data) -> [GitHub.Notification]? {
        guard let threads = try? JSONDecoder().decode([LenientElement<Thread>].self, from: body) else { return nil }
        return threads.compactMap(\.value).map(\.notification)
    }

    /// githubstatus.com's incidents, and maintenance under way.
    public static func incidents(from body: Data) -> [GitHub.Incident]? {
        guard let page = try? JSONDecoder().decode(StatusPage.self, from: body) else { return nil }
        let incidents = (page.incidents ?? []).filter { $0.status != "resolved" && $0.status != "postmortem" }
            .map { $0.incident(isMaintenance: false) }
        let maintenance = (page.scheduled_maintenances ?? []).filter {
            $0.status == "in_progress" || $0.status == "verifying"
        }
        .map { $0.incident(isMaintenance: true) }
        return incidents + maintenance
    }

    /// The page on github.com for a notification's subject, from its API address: pull requests, issues and commits
    /// open where they are, anything else at its repository.
    static func webURL(subject: String?, repository: String) -> URL? {
        let repositoryURL = URL(string: "https://github.com/\(repository)")
        guard let subject, let url = URL(string: subject), url.host() == "api.github.com" else {
            return repositoryURL
        }
        var path = url.path()
        guard path.hasPrefix("/repos/") else { return repositoryURL }
        path = String(path.dropFirst("/repos".count))
        if path.contains("/releases/") { return repositoryURL?.appending(path: "releases") }
        for (api, web) in [("/pulls/", "/pull/"), ("/commits/", "/commit/"), ("/issues/", "/issues/")]
        where path.contains(api) {
            return URL(string: "https://github.com" + path.replacingOccurrences(of: api, with: web))
        }
        return repositoryURL
    }
}

// MARK: - Decoding

extension GitHubAPI {
    private struct Payload: Decodable {
        struct Error: Decodable {
            var message: String?
            var type: String?
        }

        var data: ResponseData?
        var errors: [Error]?

        private enum CodingKeys: String, CodingKey { case data, errors }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            data = try? container.decodeIfPresent(ResponseData.self, forKey: .data)
            errors = try? container.decodeIfPresent([Error].self, forKey: .errors)
        }
    }

    /// The `data` object, whose keys are the request's aliases: `s0` searches, `r0` repositories, `c` the calendar.
    private struct ResponseData: Decodable {
        struct Viewer: Decodable { var login: String? }

        var viewer: Viewer?
        var rateLimit: GitHubRateLimit?
        var searches: [String: GitHub.SearchResult] = [:]
        var repositories: [String: GitHub.Repository] = [:]
        var contributions: GitHub.Contributions?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            viewer = try? container.decodeIfPresent(Viewer.self, forKey: AnyCodingKey("viewer"))
            if let limit = try? container.decodeIfPresent(RateLimit.self, forKey: AnyCodingKey("rateLimit")),
                let remaining = limit.remaining, let total = limit.limit
            {
                rateLimit = GitHubRateLimit(
                    remaining: remaining, limit: total, resetAt: limit.resetAt.flatMap(Date.init(iso8601:)))
            }
            for key in container.allKeys {
                let name = key.stringValue
                if name.hasPrefix("s"), Int(name.dropFirst()) != nil {
                    if let search = try? container.decodeIfPresent(Search.self, forKey: key) {
                        searches[name] = search.result
                    }
                } else if name.hasPrefix("r"), Int(name.dropFirst()) != nil {
                    let repository = try? container.decodeIfPresent(RepositoryNode.self, forKey: key)
                    repositories[name] = repository?.repository
                } else if name == "c" {
                    contributions = (try? container.decodeIfPresent(ContributionsViewer.self, forKey: key))?.calendar
                }
            }
        }
    }

    private struct RateLimit: Decodable {
        var remaining: Int?
        var limit: Int?
        var resetAt: String?
    }

    private struct Count: Decodable { var totalCount: Int? }
    private struct Login: Decodable { var login: String? }
    private struct Nodes<Node: Decodable>: Decodable { var nodes: [LenientElement<Node>]? }

    private struct Search: Decodable {
        var issueCount: Int?
        var nodes: [LenientElement<ItemNode>]?

        var result: GitHub.SearchResult {
            GitHub.SearchResult(totalCount: issueCount ?? 0, items: (nodes ?? []).compactMap { $0.value?.item })
        }
    }

    /// A pull request or an issue; both come back from a search, and empty for anything else.
    private struct ItemNode: Decodable {
        struct Repository: Decodable { var nameWithOwner: String? }
        struct LabelNode: Decodable {
            var name: String?
            var color: String?
        }
        struct CommitNode: Decodable {
            struct Commit: Decodable {
                struct Rollup: Decodable { var state: String? }
                var statusCheckRollup: Rollup?
            }
            var commit: Commit?
        }

        var number: Int?
        var title: String?
        var url: String?
        var isDraft: Bool?
        var createdAt: String?
        var updatedAt: String?
        var author: Login?
        var repository: Repository?
        var reviewDecision: String?
        var mergeable: String?
        var headRefName: String?
        var additions: Int?
        var deletions: Int?
        var comments: Count?
        var labels: Nodes<LabelNode>?
        var commits: Nodes<CommitNode>?

        var item: GitHub.Item? {
            guard let number, let title, let repository = repository?.nameWithOwner else { return nil }
            // Only pull requests have commits.
            let isPullRequest = commits != nil || isDraft != nil
            var item = GitHub.Item(
                kind: isPullRequest ? .pullRequest : .issue, repository: repository, number: number, title: title,
                url: url.flatMap(URL.init(string:)), author: author?.login,
                createdAt: createdAt.flatMap(Date.init(iso8601:)), updatedAt: updatedAt.flatMap(Date.init(iso8601:)))
            item.comments = comments?.totalCount ?? 0
            item.labels = (labels?.nodes ?? []).compactMap(\.value).compactMap { node in
                node.name.map { GitHub.Label(name: $0, color: node.color) }
            }
            item.isDraft = isDraft ?? false
            item.checks = GitHub.CheckState(
                graphQL: commits?.nodes?.last?.value?.commit?.statusCheckRollup?.state)
            item.reviewDecision = GitHub.ReviewDecision(graphQL: reviewDecision)
            item.hasConflicts = mergeable == "CONFLICTING"
            item.headBranch = headRefName
            item.additions = additions
            item.deletions = deletions
            return item
        }
    }

    private struct RepositoryNode: Decodable {
        struct Branch: Decodable {
            struct Target: Decodable {
                struct Rollup: Decodable { var state: String? }
                var messageHeadline: String?
                var committedDate: String?
                var statusCheckRollup: Rollup?
            }
            var name: String?
            var target: Target?
        }
        struct Release: Decodable {
            var tagName: String?
            var publishedAt: String?
            var url: String?
        }

        var nameWithOwner: String?
        var url: String?
        var isPrivate: Bool?
        var stargazerCount: Int?
        var pullRequests: Count?
        var issues: Count?
        var defaultBranchRef: Branch?
        var latestRelease: Release?

        var repository: GitHub.Repository? {
            guard let nameWithOwner else { return nil }
            var repository = GitHub.Repository(name: nameWithOwner, url: url.flatMap(URL.init(string:)))
            repository.isPrivate = isPrivate ?? false
            repository.stars = stargazerCount ?? 0
            repository.openPullRequests = pullRequests?.totalCount ?? 0
            repository.openIssues = issues?.totalCount ?? 0
            repository.defaultBranch = defaultBranchRef?.name
            repository.branchChecks = GitHub.CheckState(graphQL: defaultBranchRef?.target?.statusCheckRollup?.state)
            repository.lastCommitTitle = defaultBranchRef?.target?.messageHeadline
            repository.lastCommitDate = defaultBranchRef?.target?.committedDate.flatMap(Date.init(iso8601:))
            if let release = latestRelease, let tag = release.tagName {
                repository.latestRelease = GitHub.Release(
                    tag: tag, publishedAt: release.publishedAt.flatMap(Date.init(iso8601:)),
                    url: release.url.flatMap(URL.init(string:)))
            }
            return repository
        }
    }

    private struct ContributionsViewer: Decodable {
        struct Collection: Decodable {
            struct Calendar: Decodable {
                struct Week: Decodable { var contributionDays: [LenientElement<Day>]? }
                struct Day: Decodable {
                    var date: String
                    var contributionCount: Int?
                    var contributionLevel: String?
                }
                var totalContributions: Int?
                var weeks: [Week]?
            }
            var contributionCalendar: Calendar?
        }
        var contributionsCollection: Collection?

        var calendar: GitHub.Contributions? {
            guard let calendar = contributionsCollection?.contributionCalendar else { return nil }
            let days = (calendar.weeks ?? []).flatMap { $0.contributionDays ?? [] }.compactMap(\.value).map { day in
                GitHub.Contributions.Day(
                    date: day.date, count: day.contributionCount ?? 0, level: Self.level(day.contributionLevel))
            }
            return GitHub.Contributions(total: calendar.totalContributions ?? 0, days: days)
        }

        static func level(_ value: String?) -> Int {
            switch value {
            case "FIRST_QUARTILE": 1
            case "SECOND_QUARTILE": 2
            case "THIRD_QUARTILE": 3
            case "FOURTH_QUARTILE": 4
            default: 0
            }
        }
    }

    private struct Thread: Decodable {
        struct Subject: Decodable {
            var title: String?
            var url: String?
            var type: String?
        }
        struct Repository: Decodable { var full_name: String? }

        var id: String
        var reason: String?
        var updated_at: String?
        var subject: Subject?
        var repository: Repository?

        var notification: GitHub.Notification {
            let repository = repository?.full_name ?? ""
            return GitHub.Notification(
                id: id, title: subject?.title ?? "Notification", subject: .init(subject?.type ?? ""),
                reason: reason ?? "", repository: repository, updatedAt: updated_at.flatMap(Date.init(iso8601:)),
                url: GitHubAPI.webURL(subject: subject?.url, repository: repository))
        }
    }

    private struct StatusPage: Decodable {
        struct Entry: Decodable {
            var id: String
            var name: String?
            var status: String?
            var impact: String?
            var shortlink: String?

            func incident(isMaintenance: Bool) -> GitHub.Incident {
                GitHub.Incident(
                    id: id, title: name ?? "Incident", status: status, impact: impact, isMaintenance: isMaintenance,
                    url: shortlink.flatMap(URL.init(string:)))
            }
        }

        var incidents: [Entry]?
        var scheduled_maintenances: [Entry]?
    }
}

extension GitHubRateLimit: Decodable {
    private enum CodingKeys: String, CodingKey { case remaining, limit, resetAt }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remaining = try container.decode(Int.self, forKey: .remaining)
        limit = try container.decode(Int.self, forKey: .limit)
        resetAt = try container.decodeIfPresent(String.self, forKey: .resetAt).flatMap(Date.init(iso8601:))
    }
}

// MARK: - The GitHub CLI

/// Running `gh`, the GitHub CLI, signed in as it is. Sidelight never sees its token: `gh` makes each request itself.
public enum GitHubCLI {
    /// Where `gh` may be installed: Homebrew's and the installer's folders, MacPorts, and `~/.local/bin`.
    public static var executableDirectories: [URL] {
        ExecutableLocator.standardDirectories + [URL(filePath: "/opt/local/bin", directoryHint: .isDirectory)]
    }

    /// Settings for `gh` so it never waits for an answer, prints colors or checks for its own updates.
    public static let environment: [String: String?] = [
        "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GH_NO_EXTENSION_UPDATE_NOTIFIER": "1",
        "NO_COLOR": "1", "CLICOLOR": "0", "GH_PAGER": "cat", "PAGER": "cat",
    ]

    /// Where `gh` keeps its sign-ins: `$GH_CONFIG_DIR`, `$XDG_CONFIG_HOME/gh` or `~/.config/gh`.
    public static func configDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let folder = environment["GH_CONFIG_DIR"], !folder.isEmpty {
            return URL(filePath: folder, directoryHint: .isDirectory)
        }
        if let folder = environment["XDG_CONFIG_HOME"], !folder.isEmpty {
            return URL(filePath: folder, directoryHint: .isDirectory).appending(path: "gh", directoryHint: .isDirectory)
        }
        return URL.homeDirectory.appending(path: ".config/gh", directoryHint: .isDirectory)
    }

    /// The account `gh` uses on github.com, from its `hosts.yml`; `nil` when it's signed in to none. Reads the file
    /// only: the token lives in the keychain, and stays there.
    public static func signedInUser(hostsYAML: String) -> String? {
        var inGitHub = false
        var user: String?
        var hasUsers = false
        for line in hostsYAML.split(separator: "\n", omittingEmptySubsequences: true) {
            let indent = line.prefix { $0 == " " }.count
            let text = line.trimmingCharacters(in: .whitespaces)
            if indent == 0 {
                inGitHub = text == "github.com:"
                continue
            }
            guard inGitHub else { continue }
            if text.hasPrefix("user:") {
                let value = text.dropFirst("user:".count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { user = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            } else if text.hasPrefix("oauth_token:") || text == "users:" {
                hasUsers = true
            }
        }
        return user ?? (hasUsers ? "" : nil)
    }

    /// `gh api graphql` with the request's document and variables.
    public static func graphQLArguments(_ request: GitHubRequest) -> [String] {
        var arguments = ["api", "graphql", "-f", "query=\(request.document)"]
        for (name, value) in request.variables.sorted(by: { $0.key < $1.key }) {
            arguments += ["-f", "\(name)=\(value)"]
        }
        return arguments
    }

    /// `gh api <path>`: a GET to the REST API.
    public static func restArguments(path: String) -> [String] {
        ["api", "--method", "GET", "-H", "Accept: application/vnd.github+json", path]
    }

    /// What went wrong, from how `gh` exited and what it said. `nil` when its output is an answer to read: it exits
    /// with an error when a GraphQL answer has any, even alongside data.
    public static func problem(status: Int32, output: Data, error: Data) -> GitHubFetchProblem? {
        let printedJSON = output.first.map { $0 == UInt8(ascii: "{") || $0 == UInt8(ascii: "[") } ?? false
        if status == 0 { return printedJSON || output.isEmpty ? nil : .unreadable }
        let message = String(decoding: error, as: UTF8.self)
        let lowered = message.lowercased()
        if lowered.contains("gh auth login") || lowered.contains("not logged in") { return .cliNotSignedIn }
        if lowered.contains("http 401") || lowered.contains("bad credentials") { return .rejected }
        if lowered.contains("rate limit") { return .rateLimited(until: nil) }
        // A GraphQL answer with errors: its data, if any, says the rest.
        if printedJSON, output.range(of: Data("\"data\"".utf8)) != nil { return nil }
        if lowered.contains("http 403") {
            return .notPermitted(firstLine(of: message).map { $0.replacingOccurrences(of: "gh: ", with: "") })
        }
        let offline = [
            "error connecting to", "dial tcp", "no such host", "i/o timeout", "connection refused",
            "network is unreachable", "tls handshake", "context deadline exceeded",
        ]
        if offline.contains(where: lowered.contains) || lowered.contains("http 5") { return .unreachable }
        let line = firstLine(of: message).map { $0.hasPrefix("gh: ") ? String($0.dropFirst(4)) : $0 }
        return .failed(line ?? "gh exited with status \(status).")
    }

    private static func firstLine(of text: String) -> String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}
