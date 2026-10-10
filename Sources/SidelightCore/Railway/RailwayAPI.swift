import Foundation

/// Railway's public GraphQL API: the requests Sidelight sends, and reading what comes back. Everything a widget
/// shows comes from one request per refresh; the bill and commits ride along only when a widget shows them.
public enum RailwayAPI {
    public static let endpoint = URL(string: "https://backboard.railway.com/graphql/v2")!
    /// Railway's status page, outside the API and its rate limit.
    public static let statusPage = URL(string: "https://status.railway.com/api/status")!
    public static let statusPageWebsite = URL(string: "https://status.railway.com")!

    /// Projects and services asked for per workspace. Enough for nearly everyone, and keeps the response small.
    static let projectLimit = 50
    static let serviceLimit = 100
    /// Commits asked for in one request.
    public static let commitBatchSize = 20

    /// A request with an account, workspace or OAuth token. The token is only ever sent to Railway's API.
    public static func request(
        _ document: String, variables: [String: String] = [:], token: String, userAgent: String
    )
        -> URLRequest
    {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONEncoder().encode(Body(query: document, variables: variables))
        return request
    }

    private struct Body: Encodable {
        var query: String
        var variables: [String: String]
    }

    // MARK: Documents

    /// The signed-in person and their workspaces.
    public static let accountQuery = "query SidelightAccount { me { name workspaces { id name } } }"

    /// A service in one environment to ask about in detail: CPU, memory and its latest few deploys.
    public struct DetailRequest: Hashable, Sendable {
        public var projectID: String
        public var serviceID: String
        public var environmentID: String

        public init(projectID: String, serviceID: String, environmentID: String) {
            self.projectID = projectID
            self.serviceID = serviceID
            self.environmentID = environmentID
        }
    }

    /// The window of CPU and memory a Service block draws, and how finely.
    static let metricsWindow: TimeInterval = 60 * 60
    static let metricsStep = 300
    /// Deploys a Service block shows as dots.
    public static let historyLength = 6

    /// Each workspace's projects, services and their latest deploys as `w0`, `w1`…, with variables of the same
    /// names holding the workspace IDs. With `includesUsage`, also each workspace's bill so far and the usage
    /// estimate for the rest of the period as `e0`, `e1`…. With `details`, also each one's metrics as `m0`… and
    /// latest deploys as `h0`…. See ``statusVariables(workspaceIDs:details:now:)``.
    public static func statusQuery(workspaceCount: Int, includesUsage: Bool, detailCount: Int = 0) -> String {
        let indices = 0..<workspaceCount
        var declarations = indices.map { "$w\($0): String!" }
        if detailCount > 0 {
            declarations += (0..<detailCount).map { "$p\($0): String!, $s\($0): String!, $v\($0): String!" }
            declarations.append("$since: DateTime!")
        }
        let variables = declarations.joined(separator: ", ")
        let customer =
            includesUsage
            ? "customer { currentUsage billingPeriod { start end } usageLimit { softLimit hardLimit isOverLimit } }"
            : ""
        let fields = indices.map { index in
            var field = """
                w\(index): workspace(workspaceId: $w\(index)) { id name plan \(customer)
                projects(first: \(projectLimit)) { edges { node { id name primaryEnvironmentId deletedAt
                environments { edges { node { id name isEphemeral } } }
                services(first: \(serviceLimit)) { edges { node { id name icon
                serviceInstances { edges { node { environmentId sleepApplication
                latestDeployment { id status createdAt staticUrl } } } } } } } } } } }
                """
            if includesUsage {
                let measurements = Pricing.measurements.joined(separator: ", ")
                field += """

                    e\(index): estimatedUsage(workspaceId: $w\(index), measurements: [\(measurements)], \
                    includeDeleted: true) { measurement estimatedValue }
                    """
            }
            return field
        }
        let details = (0..<detailCount).map { index in
            let target = "projectId: $p\(index), serviceId: $s\(index), environmentId: $v\(index)"
            return """
                m\(index): metrics(\(target), startDate: $since, measurements: [CPU_USAGE, MEMORY_USAGE_GB], \
                sampleRateSeconds: \(metricsStep)) { measurement values { ts value } }
                h\(index): deployments(first: \(historyLength), input: { \(target) }) \
                { edges { node { id status createdAt } } }
                """
        }
        let body = (fields + details).joined(separator: "\n")
        return "query SidelightStatus\(variables.isEmpty ? "" : "(\(variables))") {\n\(body)\n}"
    }

    /// The variables for ``statusQuery(workspaceCount:includesUsage:detailCount:)``.
    public static func statusVariables(workspaceIDs: [String], details: [DetailRequest], now: Date) -> [String: String]
    {
        var variables: [String: String] = [:]
        for (index, id) in workspaceIDs.enumerated() { variables["w\(index)"] = id }
        for (index, detail) in details.enumerated() {
            variables["p\(index)"] = detail.projectID
            variables["s\(index)"] = detail.serviceID
            variables["v\(index)"] = detail.environmentID
        }
        if !details.isEmpty {
            variables["since"] = now.addingTimeInterval(-metricsWindow).formatted(.iso8601)
        }
        return variables
    }

    /// Deploys' commits as `d0`, `d1`…, with variables of the same names holding the deploy IDs. A deploy's
    /// `meta` is large (it carries the whole service manifest), so this asks only for deploys not seen before.
    public static func commitsQuery(count: Int) -> String {
        let indices = 0..<count
        let variables = indices.map { "$d\($0): String!" }.joined(separator: ", ")
        let fields = indices.map { "d\($0): deployment(id: $d\($0)) { id meta }" }
        return "query SidelightCommits(\(variables)) {\n\(fields.joined(separator: "\n"))\n}"
    }

    // MARK: Responses

    public struct Account: Equatable, Sendable {
        public struct Workspace: Equatable, Sendable {
            public var id: String
            public var name: String

            public init(id: String, name: String) {
                self.id = id
                self.name = name
            }
        }

        public var name: String?
        public var workspaces: [Workspace]
    }

    /// Reads a response to ``accountQuery``.
    public static func account(status: Int, body: Data) -> Result<Account, RailwayFetchProblem> {
        decode(AccountData.self, status: status, body: body).map { data in
            Account(
                name: data.me.name, workspaces: data.me.workspaces.map { Account.Workspace(id: $0.id, name: $0.name) })
        }
    }

    /// What a status request answered: the workspaces, and the details in the order they were asked for.
    public struct Status: Equatable, Sendable {
        public var workspaces: [Railway.Workspace]
        /// `nil` for a service the sign-in can't see.
        public var details: [Railway.ServiceDetail?]
    }

    /// Reads a response to ``statusQuery(workspaceCount:includesUsage:detailCount:)``. A workspace or service the
    /// sign-in can't see is left out rather than failing the rest.
    public static func status(
        status: Int, body: Data, workspaceCount: Int, detailCount: Int = 0
    ) -> Result<Status, RailwayFetchProblem> {
        decode(StatusData.self, status: status, body: body).map { data in
            Status(
                workspaces: (0..<workspaceCount).compactMap { index in
                    data.workspaces["w\(index)"].map { $0.workspace(estimates: data.estimates["e\(index)"]) }
                },
                details: (0..<detailCount).map { index in
                    let metrics = data.metrics["m\(index)"]
                    let history = data.history["h\(index)"]
                    guard metrics != nil || history != nil else { return nil }
                    return Railway.ServiceDetail(
                        cpu: metrics?.first { $0.measurement == "CPU_USAGE" }?.values.map(\.value) ?? [],
                        memoryGB: metrics?.first { $0.measurement == "MEMORY_USAGE_GB" }?.values.map(\.value) ?? [],
                        recentDeploys: (history?.nodes ?? []).map {
                            Railway.Deployment(
                                id: $0.id, status: Railway.DeploymentStatus($0.status ?? ""),
                                createdAt: $0.createdAt.flatMap(RailwayDate.parse))
                        })
                })
        }
    }

    /// Reads a response to ``commitsQuery(count:)``, keyed by deploy ID.
    public static func commits(status: Int, body: Data) -> Result<[String: Railway.Commit], RailwayFetchProblem> {
        decode(CommitsData.self, status: status, body: body).map(\.commits)
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type, status: Int, body: Data
    ) -> Result<
        Value, RailwayFetchProblem
    > {
        if let problem = RailwayFetchProblem(status: status) { return .failure(problem) }
        guard let response = try? JSONDecoder().decode(GraphQLResponse<Value>.self, from: body) else {
            return .failure(.unreadable)
        }
        if let data = response.data { return .success(data) }
        let messages = response.errors?.map(\.message) ?? []
        if messages.contains(where: { $0.localizedCaseInsensitiveContains("not authorized") }) {
            return .failure(.notAuthorized)
        }
        return .failure(messages.first.map { .refused(message: $0) } ?? .unreadable)
    }
}

/// Railway's usage prices, as its CLI estimates the bill with them: per GB of memory, vCPU and GB of disk or
/// backups for a month of 30 days, and per GB sent out.
enum Pricing {
    static let measurements = ["MEMORY_USAGE_GB", "CPU_USAGE", "NETWORK_TX_GB", "DISK_USAGE_GB", "BACKUP_USAGE_GB"]
    private static let minutesInMonth = 43_200.0

    /// The usage values are per minute, except network.
    static func dollars(for measurement: String, value: Double) -> Double {
        switch measurement {
        case "MEMORY_USAGE_GB": value * 10 / minutesInMonth
        case "CPU_USAGE": value * 20 / minutesInMonth
        case "NETWORK_TX_GB": value * 0.05
        case "DISK_USAGE_GB", "BACKUP_USAGE_GB": value * 0.15 / minutesInMonth
        default: 0
        }
    }
}

/// Why asking Railway failed.
public enum RailwayFetchProblem: Error, Equatable, Sendable {
    /// Neither a Railway CLI sign-in nor a saved token.
    case notSignedIn
    /// Using the CLI was chosen, and it isn't signed in.
    case cliNotSignedIn
    /// The CLI's sign-in expired and the CLI couldn't renew it.
    case cliSignInExpired
    /// Using a token was chosen, and none is saved.
    case noToken
    /// Railway turned the sign-in down with this HTTP status.
    case rejected(status: Int)
    /// The sign-in works, but may not see this: a project token, or a workspace it isn't part of.
    case notAuthorized
    /// Railway asks to wait; for this long, when it says.
    case rateLimited(retryAfter: TimeInterval?)
    /// Railway answered with an error of its own.
    case refused(message: String)
    case unreachable
    /// A response Sidelight can't read: the API may have changed.
    case unreadable
    /// The account has no workspace, or not the chosen one.
    case noWorkspace

    /// The problem behind an HTTP status other than success, or `nil` for success.
    init?(status: Int) {
        switch status {
        case 200: return nil
        case 401, 403: self = .rejected(status: status)
        case 429: self = .rateLimited(retryAfter: nil)
        default: self = .refused(message: "HTTP \(status)")
        }
    }

    public var title: String {
        switch self {
        case .notSignedIn: "Not signed in to Railway"
        case .cliNotSignedIn: "The Railway CLI isn't signed in"
        case .cliSignInExpired: "The Railway CLI's sign-in has expired"
        case .noToken: "No Railway token saved"
        case .rejected: "Railway didn't accept the sign-in"
        case .notAuthorized: "Railway didn't allow it"
        case .rateLimited: "Railway asked to slow down"
        case .refused(let message): "Railway answered: \(message)"
        case .unreachable: "Can't reach Railway"
        case .unreadable: "No status Sidelight can read"
        case .noWorkspace: "Workspace not found"
        }
    }

    public var advice: String {
        switch self {
        case .notSignedIn: "Run railway login, or save an API token in the widget's settings."
        case .cliNotSignedIn, .cliSignInExpired: "Run railway login, or use an API token instead."
        case .noToken: "Save an account or workspace token in the widget's settings."
        case .rejected: "The token may have been revoked. Sign in again or save a new token."
        case .notAuthorized: "Use an account or workspace token; project tokens can't list projects."
        case .rateLimited: "Trying less often."
        case .refused, .unreachable: "Trying again later."
        case .unreadable: "Railway's API may have changed."
        case .noWorkspace: "Choose another workspace in the widget's settings."
        }
    }

    /// Fixed by the person rather than by waiting.
    public var needsSignIn: Bool {
        switch self {
        case .notSignedIn, .cliNotSignedIn, .cliSignInExpired, .noToken, .rejected, .notAuthorized: true
        case .rateLimited, .refused, .unreachable, .unreadable, .noWorkspace: false
        }
    }
}

/// The rate limit Railway reports with every response: requests per window, and how many are left.
public struct RailwayRateLimit: Equatable, Sendable {
    /// Requests allowed per ``window``.
    public var limit: Int?
    public var window: TimeInterval?
    public var remaining: Int?
    public var resetsAt: Date?
    /// Sent once the limit is used up.
    public var retryAfter: TimeInterval?

    public init(
        limit: Int? = nil, window: TimeInterval? = nil, remaining: Int? = nil, resetsAt: Date? = nil,
        retryAfter: TimeInterval? = nil
    ) {
        self.limit = limit
        self.window = window
        self.remaining = remaining
        self.resetsAt = resetsAt
        self.retryAfter = retryAfter
    }

    /// Reads `RateLimit-Policy` (`"default";q=1000;w=3600`), the `X-RateLimit-*` headers and `Retry-After`.
    public init(headers: [String: String], now: Date) {
        let headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        if let policy = headers["ratelimit-policy"] {
            for parameter in policy.split(separator: ";") {
                let pair = parameter.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard pair.count == 2 else { continue }
                if pair[0] == "q" { limit = Int(pair[1]) }
                if pair[0] == "w" { window = TimeInterval(pair[1]) }
            }
        }
        limit = headers["x-ratelimit-limit"].flatMap { Int($0) } ?? limit
        remaining = headers["x-ratelimit-remaining"].flatMap { Int($0) }
        // An epoch time, or seconds from now.
        resetsAt = headers["x-ratelimit-reset"].flatMap(TimeInterval.init).map {
            $0 > 1_000_000_000 ? Date(timeIntervalSince1970: $0) : now.addingTimeInterval($0)
        }
        retryAfter = headers["retry-after"].flatMap(TimeInterval.init)
    }

    /// Requests allowed per hour.
    public var hourlyLimit: Double? {
        guard let limit, limit > 0 else { return nil }
        return Double(limit) * 3600 / max(window ?? 3600, 1)
    }
}

/// How often to ask Railway. Automatic asks every two minutes while nothing happens and every few seconds during a
/// deploy, but never spends more than a small share of the account's rate limit, which the person's CLI and
/// scripts share: 5% while idle, a quarter during a deploy. That's 30 requests an hour on the Hobby plan.
public enum RailwayPacing {
    public static let idleInterval: TimeInterval = 120
    public static let deployingInterval: TimeInterval = 10
    /// The bill changes slowly; asked along with the status at most this often.
    public static let usageInterval: TimeInterval = 15 * 60
    public static let incidentsInterval: TimeInterval = 10 * 60
    /// Assumed until Railway says: the Hobby plan's.
    static let assumedHourlyLimit = 1000.0

    /// The wait before the next request, after a successful one.
    public static func interval(
        refreshMinutes: Int?, isDeploying: Bool, rateLimit: RailwayRateLimit?, now: Date
    ) -> TimeInterval {
        var interval: TimeInterval
        if let refreshMinutes {
            interval = TimeInterval(refreshMinutes) * 60
        } else {
            let hourly = rateLimit?.hourlyLimit ?? assumedHourlyLimit
            interval =
                isDeploying
                ? max(deployingInterval, 3600 / (hourly * 0.25)) : max(idleInterval, 3600 / (hourly * 0.05))
        }
        // Nearly out of requests: wait for the window to reset rather than take the last ones.
        if let rateLimit, let remaining = rateLimit.remaining, let limit = rateLimit.limit,
            remaining < limit / 10, let resetsAt = rateLimit.resetsAt
        {
            interval = max(interval, resetsAt.timeIntervalSince(now))
        }
        return interval
    }
}

// MARK: - Decoding

private struct GraphQLResponse<Value: Decodable>: Decodable {
    var data: Value?
    var errors: [GraphQLError]?
}

private struct GraphQLError: Decodable {
    var message: String
}

private struct Connection<Node: Decodable>: Decodable {
    struct Edge: Decodable {
        var node: Node
    }

    var edges: [Edge]

    var nodes: [Node] { edges.map(\.node) }
}

private struct AccountData: Decodable {
    struct Me: Decodable {
        struct Workspace: Decodable {
            var id: String
            var name: String
        }

        var name: String?
        var workspaces: [Workspace]
    }

    var me: Me
}

/// `w0`, `w1`… are workspaces, `e0`, `e1`… their usage estimates, `m0`, `m1`… services' metrics and `h0`, `h1`…
/// their latest deploys. What the sign-in can't see comes back `null` with an error, and is skipped.
private struct StatusData: Decodable {
    var workspaces: [String: WorkspaceNode] = [:]
    var estimates: [String: [Estimate]] = [:]
    var metrics: [String: [Metric]] = [:]
    var history: [String: Connection<HistoryNode>] = [:]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        for key in container.allKeys {
            let name = key.stringValue
            switch name.first {
            case "w": workspaces[name] = try? container.decode(WorkspaceNode.self, forKey: key)
            case "e": estimates[name] = try? container.decode([Estimate].self, forKey: key)
            case "m": metrics[name] = try? container.decode([Metric].self, forKey: key)
            case "h": history[name] = try? container.decode(Connection<HistoryNode>.self, forKey: key)
            default: break
            }
        }
    }
}

private struct Metric: Decodable {
    struct Value: Decodable {
        var value: Double
    }

    var measurement: String
    var values: [Value]
}

private struct HistoryNode: Decodable {
    var id: String
    var status: String?
    var createdAt: String?
}

private struct Estimate: Decodable {
    var measurement: String
    var estimatedValue: Double
}

private struct WorkspaceNode: Decodable {
    struct Customer: Decodable {
        struct Period: Decodable {
            var start: String?
            var end: String?
        }

        struct Limit: Decodable {
            var softLimit: Double?
            var hardLimit: Double?
            var isOverLimit: Bool?
        }

        var currentUsage: Double?
        var billingPeriod: Period?
        var usageLimit: Limit?
    }

    var id: String
    var name: String
    var plan: String?
    var customer: Customer?
    var projects: Connection<ProjectNode>?

    func workspace(estimates: [Estimate]?) -> Railway.Workspace {
        Railway.Workspace(
            id: id, name: name, plan: plan,
            projects: (projects?.nodes ?? []).filter { $0.deletedAt == nil }.map(\.project),
            bill: bill(estimates: estimates))
    }

    private func bill(estimates: [Estimate]?) -> Railway.Bill? {
        guard let customer, let current = customer.currentUsage else { return nil }
        // One estimate per measurement and project, deleted ones included, as Railway's CLI adds them up.
        let estimated = estimates.map { estimates in
            max(current, estimates.reduce(0) { $0 + Pricing.dollars(for: $1.measurement, value: $1.estimatedValue) })
        }
        let limit = customer.usageLimit
        return Railway.Bill(
            currentDollars: current, estimatedDollars: estimated,
            periodStart: customer.billingPeriod?.start.flatMap(RailwayDate.parse),
            periodEnd: customer.billingPeriod?.end.flatMap(RailwayDate.parse),
            softLimitDollars: limit?.softLimit, hardLimitDollars: limit?.hardLimit,
            isOverLimit: limit?.isOverLimit ?? false)
    }
}

private struct ProjectNode: Decodable {
    struct EnvironmentNode: Decodable {
        var id: String
        var name: String
        var isEphemeral: Bool?
    }

    struct ServiceNode: Decodable {
        struct InstanceNode: Decodable {
            struct DeploymentNode: Decodable {
                var id: String
                var status: String?
                var createdAt: String?
                var staticUrl: String?
            }

            var environmentId: String?
            var sleepApplication: Bool?
            var latestDeployment: DeploymentNode?
        }

        var id: String
        var name: String
        var icon: String?
        var serviceInstances: Connection<InstanceNode>?
    }

    var id: String
    var name: String
    var primaryEnvironmentId: String?
    var deletedAt: String?
    var environments: Connection<EnvironmentNode>?
    var services: Connection<ServiceNode>?

    var project: Railway.Project {
        Railway.Project(
            id: id, name: name, primaryEnvironmentID: primaryEnvironmentId,
            environments: (environments?.nodes ?? []).map {
                Railway.Environment(id: $0.id, name: $0.name, isEphemeral: $0.isEphemeral ?? false)
            },
            services: (services?.nodes ?? []).map { service in
                Railway.Service(
                    id: service.id, name: service.name,
                    icon: service.icon.flatMap { $0.hasPrefix("http") ? URL(string: $0) : nil },
                    instances: (service.serviceInstances?.nodes ?? []).compactMap { instance in
                        guard let environmentID = instance.environmentId else { return nil }
                        return Railway.Instance(
                            environmentID: environmentID, sleeps: instance.sleepApplication ?? false,
                            deployment: instance.latestDeployment.map { deployment in
                                Railway.Deployment(
                                    id: deployment.id, status: Railway.DeploymentStatus(deployment.status ?? ""),
                                    createdAt: deployment.createdAt.flatMap(RailwayDate.parse),
                                    domain: deployment.staticUrl)
                            })
                    })
            })
    }
}

private struct CommitsData: Decodable {
    var commits: [String: Railway.Commit] = [:]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        for key in container.allKeys {
            guard let node = try? container.decode(DeploymentMeta.self, forKey: key) else { continue }
            commits[node.id] = node.commit
        }
    }
}

private struct DeploymentMeta: Decodable {
    struct Meta: Decodable {
        var commitMessage: String?
        var branch: String?
        var commitHash: String?
        var commitAuthor: String?
        var image: String?
    }

    var id: String
    var meta: Meta?

    var commit: Railway.Commit {
        Railway.Commit(
            message: meta?.commitMessage, branch: meta?.branch, hash: meta?.commitHash, author: meta?.commitAuthor,
            image: meta?.image)
    }
}

/// Railway's timestamps: ISO 8601, with or without fractions of a second, of any length.
enum RailwayDate {
    static func parse(_ string: String) -> Date? {
        let withoutFraction = string.replacing(/\.\d+/, with: "", maxReplacements: 1)
        return try? Date.ISO8601FormatStyle().parse(withoutFraction)
    }
}
