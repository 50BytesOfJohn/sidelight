import Foundation

/// The pieces of a Railway widget, arranged in its builder.
public enum RailwayBlock: WidgetBlockKind, Identifiable {
    /// The workspace or project, and how its services are doing overall.
    case summary
    /// Each service with its latest deploy.
    case services
    /// The bill so far this billing period, where it's heading, and the usage limit.
    case usage
    /// Railway's own incidents and maintenance, and only while there's one.
    case incidents
    /// One service in detail. A widget can have any number, each with its options in
    /// ``RailwaySettings/serviceBlocks`` under this ID.
    case service(UUID)

    public static let fixedBlocks: [RailwayBlock] = [.summary, .services, .usage, .incidents]

    /// `summary`, …, or `service:<UUID>`.
    public init?(rawValue: String) {
        switch rawValue {
        case "summary": self = .summary
        case "services": self = .services
        case "usage": self = .usage
        case "incidents": self = .incidents
        default:
            guard rawValue.hasPrefix(Self.servicePrefix),
                let id = UUID(uuidString: String(rawValue.dropFirst(Self.servicePrefix.count)))
            else { return nil }
            self = .service(id)
        }
    }

    public var rawValue: String {
        switch self {
        case .summary: "summary"
        case .services: "services"
        case .usage: "usage"
        case .incidents: "incidents"
        case .service(let id): Self.servicePrefix + id.uuidString
        }
    }

    private static let servicePrefix = "service:"

    public var id: String { rawValue }

    public var isShownByDefault: Bool { true }
}

/// What a Railway widget shows in the minimal and bar sizes, where there's room for one value.
public enum RailwayGlance: String, Codable, CaseIterable, Identifiable, Sendable {
    /// How many services are failing or deploying, or that all is well.
    case health
    /// The bill so far this billing period.
    case usage

    public var id: Self { self }
}

public enum RailwayServiceOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Failing services first, then deploying ones, then by name.
    case attention
    case name
    /// Most recently deployed first.
    case recent

    public var id: Self { self }
}

public struct RailwaySummaryOptions: Codable, Hashable, Sendable {
    /// The workspace's name above the project's.
    public var showsWorkspace = true

    public init(showsWorkspace: Bool = true) {
        self.showsWorkspace = showsWorkspace
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsWorkspace = try container.decode(.showsWorkspace, or: true)
    }
}

public struct RailwayServicesOptions: Codable, Hashable, Sendable {
    /// What the builder offers for ``maximumRows``.
    public static let rowCountRange = 1...20

    public var order = RailwayServiceOrder.attention
    /// The latest deploy's commit message, or the image for services deployed from one. Costs one request per new
    /// deploy.
    public var showsCommit = true
    /// Serverless services that are asleep; off lists only the awake ones.
    public var showsSleeping = true
    /// Rows in the regular size; compact shows fewer.
    public var maximumRows = 8

    public init(
        order: RailwayServiceOrder = .attention, showsCommit: Bool = true, showsSleeping: Bool = true,
        maximumRows: Int = 8
    ) {
        self.order = order
        self.showsCommit = showsCommit
        self.showsSleeping = showsSleeping
        self.maximumRows = maximumRows
    }

    /// Missing options take their defaults, and an unknown order doesn't fail the whole configuration.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RailwayServicesOptions()
        order = container.decodeLeniently(.order, or: defaults.order)
        showsCommit = try container.decode(.showsCommit, or: defaults.showsCommit)
        showsSleeping = try container.decode(.showsSleeping, or: defaults.showsSleeping)
        maximumRows = try container.decode(.maximumRows, or: defaults.maximumRows).clamped(to: Self.rowCountRange)
    }
}

public struct RailwayUsageOptions: Codable, Hashable, Sendable {
    /// Where the bill is heading by the end of the billing period, at the current rate.
    public var showsEstimate = true
    /// The bill against the workspace's usage limit, when it has one.
    public var showsLimit = true

    public init(showsEstimate: Bool = true, showsLimit: Bool = true) {
        self.showsEstimate = showsEstimate
        self.showsLimit = showsLimit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsEstimate = try container.decode(.showsEstimate, or: true)
        showsLimit = try container.decode(.showsLimit, or: true)
    }
}

public struct RailwayIncidentsOptions: Codable, Hashable, Sendable {
    /// Planned maintenance as well as incidents.
    public var showsMaintenance = true

    public init(showsMaintenance: Bool = true) {
        self.showsMaintenance = showsMaintenance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsMaintenance = try container.decode(.showsMaintenance, or: true)
    }
}

/// What a Service block shows: one service, in the widget's environment.
public struct RailwayServiceBlockOptions: Codable, Hashable, Sendable {
    /// `nil` until a service is chosen.
    public var projectID: String?
    public var serviceID: String?
    /// The service's name when it was chosen, to show while Railway can't be asked.
    public var serviceName: String?
    /// The latest deploy's commit: message, branch, hash and author.
    public var showsCommit = true
    /// CPU and memory over the last hour. Asked for along with the status, in the same request.
    public var showsMetrics = true
    /// The latest few deploys, as dots.
    public var showsHistory = true

    public init(projectID: String? = nil, serviceID: String? = nil, serviceName: String? = nil) {
        self.projectID = projectID
        self.serviceID = serviceID
        self.serviceName = serviceName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
        serviceID = try container.decodeIfPresent(String.self, forKey: .serviceID)
        serviceName = try container.decodeIfPresent(String.self, forKey: .serviceName)
        showsCommit = try container.decode(.showsCommit, or: true)
        showsMetrics = try container.decode(.showsMetrics, or: true)
        showsHistory = try container.decode(.showsHistory, or: true)
    }
}

/// Each Railway block's options, side by side, so hiding a block and showing it again loses nothing.
public struct RailwayBlockOptions: Codable, Hashable, Sendable {
    public var summary = RailwaySummaryOptions()
    public var services = RailwayServicesOptions()
    public var usage = RailwayUsageOptions()
    public var incidents = RailwayIncidentsOptions()

    public init() {}

    /// Missing blocks' options take their defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RailwayBlockOptions()
        summary = try container.decode(.summary, or: defaults.summary)
        services = try container.decode(.services, or: defaults.services)
        usage = try container.decode(.usage, or: defaults.usage)
        incidents =
            try container.decode(.incidents, or: defaults.incidents)
    }
}

/// A Railway widget: whose account, which part of it, how often to ask, and which blocks to show with what
/// options.
public struct RailwaySettings: Codable, Hashable, Sendable {
    /// What the settings offer for ``refreshMinutes``, besides automatic.
    public static let refreshMinuteChoices = [1, 2, 5, 15, 30]

    /// The Railway account it reads; `nil` for the default account.
    public var account: AccountID?
    /// `nil` for the first workspace the account belongs to.
    public var workspaceID: String?
    /// The workspace's name when it was chosen, to show while Railway can't be asked.
    public var workspaceName: String?
    /// `nil` for every project in the workspace.
    public var projectID: String?
    public var projectName: String?
    /// The environment by name, so one name (like `staging`) applies across projects. `nil` for each project's
    /// primary environment, usually `production`.
    public var environmentName: String?
    /// `nil` for automatic: slow while nothing happens, quicker during a deploy, and within the account's rate
    /// limit. Otherwise every this many minutes.
    public var refreshMinutes: Int?
    public var blocks = BlockLayout<RailwayBlock>()
    public var glance = RailwayGlance.health
    public var blockOptions = RailwayBlockOptions()
    /// Each Service block's options, by its ID.
    public private(set) var serviceBlocks: [String: RailwayServiceBlockOptions] = [:]

    public init(
        account: AccountID? = nil, refreshMinutes: Int? = nil,
        blocks: BlockLayout<RailwayBlock> = BlockLayout(), glance: RailwayGlance = .health
    ) {
        self.account = account
        self.refreshMinutes = refreshMinutes
        self.blocks = blocks
        self.glance = glance
    }

    /// Missing options take their defaults, and unknown choices don't fail the whole configuration.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RailwaySettings()
        account = container.decodeLeniently(.account, or: nil)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        workspaceName = try container.decodeIfPresent(String.self, forKey: .workspaceName)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        environmentName = try container.decodeIfPresent(String.self, forKey: .environmentName)
        refreshMinutes = try container.decodeIfPresent(Int.self, forKey: .refreshMinutes)?.clamped(
            to: UsageRefresh.minuteRange)
        blocks = container.decodeLeniently(.blocks, or: defaults.blocks)
        glance = container.decodeLeniently(.glance, or: defaults.glance)
        blockOptions =
            try container.decode(.blockOptions, or: defaults.blockOptions)
        // Only the Service blocks the layout has.
        let services = try container.decodeIfPresent([String: RailwayServiceBlockOptions].self, forKey: .serviceBlocks)
        serviceBlocks = (services ?? [:]).filter { key, _ in
            UUID(uuidString: key).map { blocks.contains(.service($0)) } ?? false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case account = "accountID"
        case workspaceID, workspaceName, projectID, projectName, environmentName, refreshMinutes, blocks, glance
        case blockOptions, serviceBlocks
    }

    /// A Service block's options; the defaults until it has any.
    public func serviceOptions(_ id: UUID) -> RailwayServiceBlockOptions {
        serviceBlocks[id.uuidString] ?? RailwayServiceBlockOptions()
    }

    public mutating func setServiceOptions(_ options: RailwayServiceBlockOptions, for id: UUID) {
        guard blocks.contains(.service(id)) else { return }
        serviceBlocks[id.uuidString] = options
    }

    /// Adds a Service block, shown at the end, and returns it.
    @discardableResult
    public mutating func addServiceBlock(_ options: RailwayServiceBlockOptions = .init()) -> RailwayBlock {
        let id = UUID()
        blocks.add(.service(id))
        serviceBlocks[id.uuidString] = options
        return .service(id)
    }

    /// Removes a Service block with its options. Fixed blocks can only be hidden.
    public mutating func removeBlock(_ block: RailwayBlock) {
        blocks.remove(block)
        if case .service(let id) = block { serviceBlocks[id.uuidString] = nil }
    }

    /// The services shown in detail by Service blocks that show CPU, memory or deploys.
    private var detailedServices: Set<RailwayServiceTarget> {
        var targets = Set<RailwayServiceTarget>()
        for case .service(let id) in blocks.shownBlocks {
            let options = serviceOptions(id)
            guard options.showsMetrics || options.showsHistory, let projectID = options.projectID,
                let serviceID = options.serviceID
            else { continue }
            targets.insert(
                RailwayServiceTarget(projectID: projectID, serviceID: serviceID, environmentName: environmentName))
        }
        return targets
    }

    /// What this widget needs fetched, given what it shows.
    public var needs: RailwayNeeds {
        let shown = Set(blocks.shownBlocks)
        let serviceCommits = shown.contains { block in
            if case .service(let id) = block { serviceOptions(id).showsCommit } else { false }
        }
        return RailwayNeeds(
            usage: shown.contains(.usage) || glance == .usage,
            incidents: shown.contains(.incidents),
            commits: shown.contains(.services) && blockOptions.services.showsCommit || serviceCommits,
            refreshMinutes: refreshMinutes,
            workspaceIDs: [workspaceID],
            environmentNames: [environmentName],
            services: detailedServices
        )
    }
}

/// What the Railway widgets on screen need.
public struct RailwayDemand: Equatable, Sendable {
    /// A Railway widget is shown, whether or not it has an account to use.
    public var isShown = false
    /// What each account the widgets use needs fetched.
    public var accounts: [AccountID: RailwayNeeds] = [:]

    public init(isShown: Bool = false, accounts: [AccountID: RailwayNeeds] = [:]) {
        self.isShown = isShown || !accounts.isEmpty
        self.accounts = accounts
    }
}

/// What Railway widgets need fetched with one account. Several widgets' needs merge into one set of requests.
public struct RailwayNeeds: Equatable, Sendable {
    /// The bill, estimate and usage limit.
    public var usage = false
    /// Railway's status page.
    public var incidents = false
    /// Each latest deploy's commit message or image.
    public var commits = false
    /// The shortest fixed interval asked for; `nil` while any widget is automatic or none fixed one.
    public var refreshMinutes: Int?
    /// The workspaces shown; `nil` stands for the account's first.
    public var workspaceIDs: Set<String?> = []
    /// The environments shown, by name; `nil` stands for each project's primary one.
    public var environmentNames: Set<String?> = []
    /// Services shown in detail, whose CPU, memory and recent deploys are asked for.
    public var services: Set<RailwayServiceTarget> = []

    public init(
        usage: Bool = false, incidents: Bool = false, commits: Bool = false, refreshMinutes: Int? = nil,
        workspaceIDs: Set<String?> = [], environmentNames: Set<String?> = [], services: Set<RailwayServiceTarget> = []
    ) {
        self.usage = usage
        self.incidents = incidents
        self.commits = commits
        self.refreshMinutes = refreshMinutes
        self.workspaceIDs = workspaceIDs
        self.environmentNames = environmentNames
        self.services = services
    }

    /// Whether `other` already fetches everything this needs, so changing from `other` to this needn't ask sooner.
    public func isCovered(by other: RailwayNeeds) -> Bool {
        (!usage || other.usage) && (!incidents || other.incidents) && (!commits || other.commits)
            && workspaceIDs.isSubset(of: other.workspaceIDs) && environmentNames.isSubset(of: other.environmentNames)
            && services.isSubset(of: other.services) && pace >= other.pace
    }

    /// Roughly how many minutes between refreshes, automatic counting as its idle pace, to tell quicker from slower.
    private var pace: Double { refreshMinutes.map(Double.init) ?? RailwayPacing.idleInterval / 60 }

    /// Both widgets' needs. An automatic widget makes the pair automatic: it may ask more often than a fixed one.
    public func merged(with other: RailwayNeeds) -> RailwayNeeds {
        RailwayNeeds(
            usage: usage || other.usage,
            incidents: incidents || other.incidents,
            commits: commits || other.commits,
            refreshMinutes: refreshMinutes.flatMap { mine in other.refreshMinutes.map { min(mine, $0) } },
            workspaceIDs: workspaceIDs.union(other.workspaceIDs),
            environmentNames: environmentNames.union(other.environmentNames),
            services: services.union(other.services)
        )
    }
}

/// A service in an environment named as a widget names it: `nil` for each project's primary one.
public struct RailwayServiceTarget: Hashable, Sendable {
    public var projectID: String
    public var serviceID: String
    public var environmentName: String?

    public init(projectID: String, serviceID: String, environmentName: String? = nil) {
        self.projectID = projectID
        self.serviceID = serviceID
        self.environmentName = environmentName
    }
}
