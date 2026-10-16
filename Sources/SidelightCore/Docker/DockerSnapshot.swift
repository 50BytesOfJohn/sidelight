import Foundation

/// Every container in one Docker context, as last read, and what they add up to.
public struct DockerSnapshot: Hashable, Sendable {
    public var containers: [DockerContainer]
    public var fetchedAt: Date

    public init(containers: [DockerContainer], fetchedAt: Date) {
        self.containers = containers
        self.fetchedAt = fetchedAt
    }

    /// Exit codes of a clean exit, Ctrl-C (SIGINT), `docker kill` (SIGKILL) and `docker stop` (SIGTERM): never a
    /// crash, unless the kernel killed it for running out of memory.
    static let deliberateExitCodes: Set<Int> = [0, 130, 137, 143]

    /// What `container`'s state means. An exit is a crash only when it's an error, its project still has a running
    /// container, and it came after the earliest of those started: a leftover from an earlier run, a clean exit or
    /// a stop stays a plain exit, and so does everything when Docker itself quits (nothing is left running).
    public func condition(of container: DockerContainer) -> DockerCondition {
        let condition = DockerCondition(container)
        guard case .exited(let code) = condition, container.oomKilled || !Self.deliberateExitCodes.contains(code),
            let project = container.project, let finishedAt = container.finishedAt
        else { return condition }
        let siblingsStarted = containers.filter {
            $0.project == project && $0.id != container.id && $0.state == .running
        }
        .compactMap(\.startedAt)
        guard let earliest = siblingsStarted.min(), finishedAt > earliest else { return condition }
        return .crashed(code: code)
    }

    public var summary: DockerSummary {
        var running = 0
        var stopped = 0
        var issues: [DockerContainer] = []
        var titles: [String] = []
        for container in containers {
            let condition = condition(of: container)
            if condition.isRunning { running += 1 }
            if !condition.isActive { stopped += 1 }
            if let title = condition.issueTitle {
                issues.append(container)
                titles.append(title)
            }
        }
        return DockerSummary(running: running, stopped: stopped, issues: issues, issueTitles: titles)
    }

    /// Groups for the panel and the details: projects with issues first, then active projects A–Z, then containers
    /// without a project as one group (`project == nil`, titled "Other containers"); inactive groups last. Groups
    /// with no container in `scope` that matches `search` are left out.
    public func groups(scope: DockerScope, search: DockerSearch = .init("")) -> [DockerGroup] {
        let shown = containers.filter { container in
            (scope == .all || condition(of: container).isActive) && search.matches(container)
        }
        let byProject = Dictionary(grouping: shown, by: \.project)
        let groups = byProject.map { project, containers in
            DockerGroup(
                project: project,
                containers: containers.sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                },
                condition: condition(of:))
        }
        return groups.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if (a.project == nil) != (b.project == nil) { return b.project == nil }
            return (a.project ?? "").localizedStandardCompare(b.project ?? "") == .orderedAscending
        }
    }
}

public enum DockerScope: Hashable, Sendable {
    /// Running, paused, and anything that's an issue.
    case active
    case all
}

/// One Compose project's containers, or every container that isn't in one.
public struct DockerGroup: Identifiable, Hashable, Sendable {
    /// `nil` for containers outside any Compose project.
    public var project: String?
    /// By display name.
    public var containers: [DockerContainer]
    public var runningCount: Int
    /// An issue beats starting, which beats running or healthy.
    public var worst: DockerCondition
    /// Each container's condition, by ID.
    public var conditions: [DockerContainer.ID: DockerCondition]
    /// Its running containers' published ports: one per host port and transport, by host port then transport.
    public var ports: [DockerPort]

    init(project: String?, containers: [DockerContainer], condition: (DockerContainer) -> DockerCondition) {
        self.project = project
        self.containers = containers
        let conditions = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, condition($0)) })
        self.conditions = conditions
        runningCount = conditions.values.count(where: \.isRunning)
        worst =
            containers.map { conditions[$0.id]! }.max { $0.severity < $1.severity } ?? .other("")
        var ports: [DockerPort] = []
        for container in containers where conditions[container.id]!.isRunning {
            for port in container.ports
            where !ports.contains(where: { $0.hostPort == port.hostPort && $0.transport == port.transport }) {
                ports.append(port)
            }
        }
        self.ports = ports.sorted { ($0.hostPort, $0.transport) < ($1.hostPort, $1.transport) }
    }

    public var id: String { project.map { "project:\($0)" } ?? "standalone" }
    /// The project's name, or `Other containers`.
    public var title: String { project ?? "Other containers" }
    /// Containers with issues, worst first.
    public var issues: [DockerContainer] {
        containers.filter { conditions[$0.id]?.isIssue == true }
            .sorted { (conditions[$0.id]?.severity ?? 0) > (conditions[$1.id]?.severity ?? 0) }
    }
    /// Something in it is running, paused or an issue.
    public var isActive: Bool { conditions.values.contains(where: \.isActive) }

    public func condition(of container: DockerContainer) -> DockerCondition {
        conditions[container.id] ?? DockerCondition(container)
    }

    fileprivate var tier: Int { worst.isIssue ? 0 : isActive ? 1 : 2 }
}

/// What a snapshot's containers add up to.
public struct DockerSummary: Hashable, Sendable {
    public var running: Int
    /// Neither running nor an issue: exited, created, …
    public var stopped: Int
    /// Containers that are an issue.
    public var issues: [DockerContainer]
    private var issueTitles: [String]

    public init(running: Int, stopped: Int, issues: [DockerContainer], issueTitles: [String]) {
        self.running = running
        self.stopped = stopped
        self.issues = issues
        self.issueTitles = issueTitles
    }

    /// `6 running`, `6 running · 1 unhealthy`, `6 running · 2 issues`, `None running`.
    public var headline: String {
        let count = running == 0 ? "None running" : "\(running) running"
        return issueText.map { "\(count) · \($0)" } ?? count
    }

    /// `1 unhealthy`, `2 crashed`, or `2 issues` when they're of different kinds; `nil` without issues.
    public var issueText: String? {
        guard let first = issueTitles.first else { return nil }
        if issueTitles.allSatisfy({ $0 == first }) { return "\(issueTitles.count) \(first)" }
        return "\(issueTitles.count) issues"
    }
}

/// What someone typed to find containers: matched, ignoring case and accents, against the name, service, project and
/// image, and against port numbers.
public struct DockerSearch: Hashable, Sendable {
    let text: String

    public init(_ text: String) {
        self.text = text.trimmingCharacters(in: .whitespaces)
    }

    public var isEmpty: Bool { text.isEmpty }

    public func matches(_ container: DockerContainer) -> Bool {
        guard !text.isEmpty else { return true }
        let fields = [container.name, container.service, container.project, container.image].compactMap(\.self)
        if fields.contains(where: { $0.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
            return true
        }
        let digits = text.hasPrefix(":") ? String(text.dropFirst()) : text
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return false }
        return container.ports.contains { String($0.hostPort).hasPrefix(digits) || String($0.containerPort) == digits }
    }
}

extension DockerSnapshot {
    /// For previews: a `storefront` project whose API is unhealthy, a standalone `minio`, and a stopped project.
    public static func sample(at now: Date) -> DockerSnapshot {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func id(_ n: Int) -> String { String(repeating: String(n), count: 64) }
        let containers = [
            DockerContainer(
                id: id(1), name: "storefront-web-1", image: "storefront-web", state: .running, health: .healthy,
                startedAt: ago(130), project: "storefront", service: "web",
                ports: [DockerPort(hostPort: 3000, containerPort: 3000)]),
            DockerContainer(
                id: id(2), name: "storefront-api-1", image: "storefront-api", state: .running, health: .unhealthy,
                startedAt: ago(128), project: "storefront", service: "api",
                ports: [DockerPort(hostPort: 8080, containerPort: 80)]),
            DockerContainer(
                id: id(3), name: "storefront-db-1", image: "postgres:17", state: .running, health: .healthy,
                startedAt: ago(131), project: "storefront", service: "db",
                ports: [DockerPort(hostPort: 5432, containerPort: 5432)]),
            DockerContainer(
                id: id(4), name: "storefront-redis-1", image: "redis:8", state: .running, startedAt: ago(131),
                project: "storefront", service: "redis"),
            DockerContainer(
                id: id(5), name: "minio", image: "minio/minio", state: .running, startedAt: ago(60 * 26),
                ports: [
                    DockerPort(hostPort: 9000, containerPort: 9000), DockerPort(hostPort: 9001, containerPort: 9001),
                ]
            ),
            DockerContainer(
                id: id(6), name: "blog-app-1", image: "blog-app", state: .exited, startedAt: ago(60 * 50),
                finishedAt: ago(60 * 30), exitCode: 0, project: "blog", service: "app"),
            DockerContainer(
                id: id(7), name: "blog-db-1", image: "mysql:9", state: .exited, startedAt: ago(60 * 50),
                finishedAt: ago(60 * 30), exitCode: 0, project: "blog", service: "db"),
        ]
        return DockerSnapshot(containers: containers, fetchedAt: now)
    }
}
