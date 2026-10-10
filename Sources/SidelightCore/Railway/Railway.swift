import Foundation

/// What Sidelight knows about a Railway account: its workspaces, their projects and services with each one's latest
/// deploy, the bill, and Railway's own incidents.
public enum Railway {
    public struct Snapshot: Equatable, Sendable {
        /// The signed-in person's name, when the sign-in belongs to one rather than to a workspace.
        public var userName: String?
        public var workspaces: [Workspace]
        /// Railway's incidents and maintenance; `nil` when not asked for or unknown.
        public var incidents: [Incident]?
        public var fetchedAt: Date

        public init(userName: String? = nil, workspaces: [Workspace], incidents: [Incident]? = nil, fetchedAt: Date) {
            self.userName = userName
            self.workspaces = workspaces
            self.incidents = incidents
            self.fetchedAt = fetchedAt
        }

        /// The workspace with `id`, or the first one for `nil`.
        public func workspace(id: String?) -> Workspace? {
            guard let id else { return workspaces.first }
            return workspaces.first { $0.id == id }
        }

        /// Whether any service is building or deploying, in any workspace: worth asking more often.
        public var isDeploying: Bool {
            workspaces.contains { workspace in
                workspace.projects.contains { project in
                    project.services.contains { service in
                        service.instances.contains { $0.deployment?.status.health == .deploying }
                    }
                }
            }
        }

        /// Where to ask about `target`: its project and the environment it names. `nil` while unknown.
        public func detailRequest(for target: RailwayServiceTarget) -> RailwayAPI.DetailRequest? {
            let project = workspaces.lazy.flatMap(\.projects).first { $0.id == target.projectID }
            guard let environment = project?.environment(named: target.environmentName) else { return nil }
            return RailwayAPI.DetailRequest(
                projectID: target.projectID, serviceID: target.serviceID, environmentID: environment.id)
        }

        /// IDs of every latest deploy, to fetch their commits.
        public var deploymentIDs: Set<String> {
            Set(
                workspaces.flatMap(\.projects).flatMap(\.services).flatMap(\.instances)
                    .compactMap(\.deployment?.id))
        }
    }

    public struct Workspace: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        /// Such as `HOBBY` or `PRO`.
        public var plan: String?
        public var projects: [Project]
        /// `nil` when not asked for, or not visible to the sign-in.
        public var bill: Bill?

        public init(id: String, name: String, plan: String? = nil, projects: [Project], bill: Bill? = nil) {
            self.id = id
            self.name = name
            self.plan = plan
            self.projects = projects
            self.bill = bill
        }
    }

    public struct Project: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var primaryEnvironmentID: String?
        public var environments: [Environment]
        public var services: [Service]

        public init(
            id: String, name: String, primaryEnvironmentID: String? = nil, environments: [Environment],
            services: [Service]
        ) {
            self.id = id
            self.name = name
            self.primaryEnvironmentID = primaryEnvironmentID
            self.environments = environments
            self.services = services
        }

        /// The environment called `name`, or for `nil` the primary one: the one named `production`, failing that,
        /// or the first.
        public func environment(named name: String?) -> Environment? {
            if let name { return environments.first { $0.name == name } }
            return environments.first { $0.id == primaryEnvironmentID }
                ?? environments.first { $0.name == "production" } ?? environments.first
        }
    }

    public struct Environment: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        /// A pull request's environment, gone once it's merged.
        public var isEphemeral: Bool

        public init(id: String, name: String, isEphemeral: Bool = false) {
            self.id = id
            self.name = name
            self.isEphemeral = isEphemeral
        }
    }

    public struct Service: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        /// Its icon in Railway's dashboard, such as a database's logo.
        public var icon: URL?
        /// One per environment the service is in.
        public var instances: [Instance]

        public init(id: String, name: String, icon: URL? = nil, instances: [Instance]) {
            self.id = id
            self.name = name
            self.icon = icon
            self.instances = instances
        }
    }

    /// A service in one environment.
    public struct Instance: Equatable, Sendable {
        public var environmentID: String
        /// Serverless: asleep while nobody uses it.
        public var sleeps: Bool
        public var deployment: Deployment?

        public init(environmentID: String, sleeps: Bool = false, deployment: Deployment? = nil) {
            self.environmentID = environmentID
            self.sleeps = sleeps
            self.deployment = deployment
        }
    }

    public struct Deployment: Identifiable, Equatable, Sendable {
        public var id: String
        public var status: DeploymentStatus
        public var createdAt: Date?
        /// The service's Railway domain, without a scheme.
        public var domain: String?

        public init(id: String, status: DeploymentStatus, createdAt: Date? = nil, domain: String? = nil) {
            self.id = id
            self.status = status
            self.createdAt = createdAt
            self.domain = domain
        }
    }

    public enum DeploymentStatus: Equatable, Sendable {
        case queued, waiting, needsApproval, initializing, building, deploying
        case success, sleeping
        case crashed, failed
        case removing, removed, skipped
        case other(String)

        public init(_ value: String) {
            self =
                switch value.uppercased() {
                case "QUEUED": .queued
                case "WAITING": .waiting
                case "NEEDS_APPROVAL": .needsApproval
                case "INITIALIZING": .initializing
                case "BUILDING": .building
                case "DEPLOYING": .deploying
                case "SUCCESS": .success
                case "SLEEPING": .sleeping
                case "CRASHED": .crashed
                case "FAILED": .failed
                case "REMOVING": .removing
                case "REMOVED": .removed
                case "SKIPPED": .skipped
                default: .other(value)
                }
        }

        public var health: Health {
            switch self {
            case .crashed, .failed: .failing
            case .queued, .waiting, .needsApproval, .initializing, .building, .deploying, .removing: .deploying
            case .success: .running
            case .sleeping: .sleeping
            case .removed, .skipped, .other: .inactive
            }
        }
    }

    /// How a service is doing, worst first: the order the services block sorts by.
    public enum Health: Int, Comparable, CaseIterable, Sendable {
        case failing, deploying, running, sleeping, inactive

        public static func < (lhs: Health, rhs: Health) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One service in detail, for a Service block.
    public struct ServiceDetail: Equatable, Sendable {
        /// vCPUs used, every five minutes over the last hour, oldest first.
        public var cpu: [Double]
        /// GB of memory used, likewise.
        public var memoryGB: [Double]
        /// The latest few deploys, newest first. Railway marks a deploy a later one replaced as removed.
        public var recentDeploys: [Deployment]

        public init(cpu: [Double] = [], memoryGB: [Double] = [], recentDeploys: [Deployment] = []) {
            self.cpu = cpu
            self.memoryGB = memoryGB
            self.recentDeploys = recentDeploys
        }
    }

    /// Where a deploy came from: a commit, or an image.
    public struct Commit: Equatable, Sendable {
        public var message: String?
        public var branch: String?
        public var hash: String?
        public var author: String?
        /// For a service deployed from an image instead of a repository.
        public var image: String?

        public init(
            message: String? = nil, branch: String? = nil, hash: String? = nil, author: String? = nil,
            image: String? = nil
        ) {
            self.message = message
            self.branch = branch
            self.hash = hash
            self.author = author
            self.image = image
        }

        /// The message's first line, or the image.
        public var title: String? {
            let firstLine = message?.split(whereSeparator: \.isNewline).first.map(String.init)
            return firstLine ?? image
        }
    }

    /// A workspace's bill for the current billing period, in US dollars.
    public struct Bill: Equatable, Sendable {
        public var currentDollars: Double
        /// At the current rate, by the end of the period.
        public var estimatedDollars: Double?
        public var periodStart: Date?
        public var periodEnd: Date?
        /// Railway emails past this.
        public var softLimitDollars: Double?
        /// Railway stops the workspace's services past this.
        public var hardLimitDollars: Double?
        public var isOverLimit: Bool

        public init(
            currentDollars: Double, estimatedDollars: Double? = nil, periodStart: Date? = nil, periodEnd: Date? = nil,
            softLimitDollars: Double? = nil, hardLimitDollars: Double? = nil, isOverLimit: Bool = false
        ) {
            self.currentDollars = currentDollars
            self.estimatedDollars = estimatedDollars
            self.periodStart = periodStart
            self.periodEnd = periodEnd
            self.softLimitDollars = softLimitDollars
            self.hardLimitDollars = hardLimitDollars
            self.isOverLimit = isOverLimit
        }

        /// The limit the bill is measured against: the hard one, or failing that the soft one.
        public var limitDollars: Double? { hardLimitDollars ?? softLimitDollars }

        /// The bill as a percentage of ``limitDollars``.
        public var percentOfLimit: Double? {
            guard let limit = limitDollars, limit > 0 else { return nil }
            return currentDollars / limit * 100
        }
    }

    /// An incident or planned maintenance on Railway's status page.
    public struct Incident: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        /// Such as `INVESTIGATING` or `MONITORING`.
        public var status: String?
        public var isMaintenance: Bool
        public var startedAt: Date?
        /// The parts of Railway it affects.
        public var components: [String]

        public init(
            id: String, title: String, status: String? = nil, isMaintenance: Bool = false, startedAt: Date? = nil,
            components: [String] = []
        ) {
            self.id = id
            self.title = title
            self.status = status
            self.isMaintenance = isMaintenance
            self.startedAt = startedAt
            self.components = components
        }
    }
}

/// One service in the environment a widget shows.
public struct RailwayServiceRow: Identifiable, Equatable, Sendable {
    public var projectID: String
    public var projectName: String
    public var serviceID: String
    public var name: String
    public var icon: URL?
    public var environmentID: String
    public var sleeps: Bool
    public var deployment: Railway.Deployment?

    public var id: String { "\(projectID)/\(serviceID)" }

    public init(
        projectID: String, projectName: String, serviceID: String, name: String, icon: URL? = nil,
        environmentID: String, sleeps: Bool = false, deployment: Railway.Deployment? = nil
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.serviceID = serviceID
        self.name = name
        self.icon = icon
        self.environmentID = environmentID
        self.sleeps = sleeps
        self.deployment = deployment
    }

    /// A serverless service that succeeded but is asleep reads as asleep; one never deployed, as inactive.
    public var health: Railway.Health {
        guard let deployment else { return .inactive }
        if sleeps, deployment.status == .success { return .sleeping }
        return deployment.status.health
    }

    /// The service's page in Railway's dashboard.
    public var dashboardURL: URL? {
        URL(
            string:
                "https://railway.com/project/\(projectID)/service/\(serviceID)?environmentId=\(environmentID)")
    }
}

/// What one Railway widget shows of a snapshot: its workspace, its projects in the chosen environment, and their
/// services.
public struct RailwayOverview: Equatable, Sendable {
    public var workspace: Railway.Workspace
    public var projects: [Railway.Project]
    /// The environment shown, when all the projects show one of the same name.
    public var environmentName: String?
    public var rows: [RailwayServiceRow]

    /// `nil` when the chosen workspace isn't in the snapshot.
    public init?(snapshot: Railway.Snapshot, settings: RailwaySettings) {
        guard let workspace = snapshot.workspace(id: settings.workspaceID) else { return nil }
        self.workspace = workspace
        projects =
            settings.projectID.map { id in workspace.projects.filter { $0.id == id } } ?? workspace.projects
        var rows: [RailwayServiceRow] = []
        var environmentNames = Set<String>()
        for project in projects {
            guard let environment = project.environment(named: settings.environmentName) else { continue }
            environmentNames.insert(environment.name)
            for service in project.services {
                guard let instance = service.instances.first(where: { $0.environmentID == environment.id }) else {
                    continue
                }
                rows.append(
                    RailwayServiceRow(
                        projectID: project.id, projectName: project.name, serviceID: service.id, name: service.name,
                        icon: service.icon, environmentID: environment.id, sleeps: instance.sleeps,
                        deployment: instance.deployment))
            }
        }
        self.rows = rows
        environmentName = environmentNames.count == 1 ? environmentNames.first : nil
    }

    /// How many services are in each state.
    public func count(_ health: Railway.Health) -> Int {
        rows.count { $0.health == health }
    }

    /// The worst state among the services; `nil` without any.
    public var health: Railway.Health? { rows.map(\.health).min() }

    /// The project's name when one is shown, otherwise the workspace's.
    public var title: String {
        projects.count == 1 ? projects[0].name : workspace.name
    }

    /// The service with these IDs, when the widget shows it.
    public func row(projectID: String?, serviceID: String?) -> RailwayServiceRow? {
        rows.first { $0.projectID == projectID && $0.serviceID == serviceID }
    }

    /// The rows in `order`, without asleep ones unless `showsSleeping`.
    public func rows(ordered order: RailwayServiceOrder, showsSleeping: Bool) -> [RailwayServiceRow] {
        let rows = showsSleeping ? rows : rows.filter { $0.health != .sleeping }
        let byName: (RailwayServiceRow, RailwayServiceRow) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        switch order {
        case .name:
            return rows.sorted(by: byName)
        case .attention:
            return rows.sorted { $0.health == $1.health ? byName($0, $1) : $0.health < $1.health }
        case .recent:
            return rows.sorted {
                let (first, second) = (
                    $0.deployment?.createdAt ?? .distantPast, $1.deployment?.createdAt ?? .distantPast
                )
                return first == second ? byName($0, $1) : first > second
            }
        }
    }
}
