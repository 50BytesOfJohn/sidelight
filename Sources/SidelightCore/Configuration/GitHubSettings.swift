import Foundation

/// The pieces of a GitHub widget, arranged in its builder.
public enum GitHubBlock: WidgetBlockKind, Identifiable {
    /// One line of counts: reviews waiting, open pull requests, issues, unread notifications.
    case summary
    /// Pull requests waiting for the account's review.
    case reviewRequests
    /// The account's own open pull requests, with their checks and reviews.
    case pullRequests
    /// Open issues assigned to the account, opened by it, or mentioning it.
    case issues
    /// Unread notifications.
    case notifications
    /// The contribution calendar, and the streak.
    case contributions
    /// GitHub's own incidents and maintenance, and only while there's one.
    case status
    /// One repository at a glance. A widget can have any number, each with its options in
    /// ``GitHubSettings/repositoryBlocks`` under this ID.
    case repository(UUID)

    public static let fixedBlocks: [GitHubBlock] = [
        .summary, .reviewRequests, .pullRequests, .issues, .notifications, .contributions, .status,
    ]

    /// `summary`, …, or `repository:<UUID>`.
    public init?(rawValue: String) {
        switch rawValue {
        case "summary": self = .summary
        case "reviewRequests": self = .reviewRequests
        case "pullRequests": self = .pullRequests
        case "issues": self = .issues
        case "notifications": self = .notifications
        case "contributions": self = .contributions
        case "status": self = .status
        default:
            guard rawValue.hasPrefix(Self.repositoryPrefix),
                let id = UUID(uuidString: String(rawValue.dropFirst(Self.repositoryPrefix.count)))
            else { return nil }
            self = .repository(id)
        }
    }

    public var rawValue: String {
        switch self {
        case .summary: "summary"
        case .reviewRequests: "reviewRequests"
        case .pullRequests: "pullRequests"
        case .issues: "issues"
        case .notifications: "notifications"
        case .contributions: "contributions"
        case .status: "status"
        case .repository(let id): Self.repositoryPrefix + id.uuidString
        }
    }

    private static let repositoryPrefix = "repository:"

    public var id: String { rawValue }

    /// Blocks a later version adds start hidden in saved layouts; new widgets start from ``GitHubPreset/focus``.
    public var isShownByDefault: Bool { false }
}

/// Ready-made layouts for a GitHub widget. The first is the default: a few lines that matter, with nothing shown
/// for what's empty.
public enum GitHubPreset: String, CaseIterable, Identifiable, Sendable {
    /// Reviews waiting and your own pull requests.
    case focus
    /// One line of counts.
    case glance
    /// The inbox, reviews waiting and issues.
    case triage
    /// The contribution calendar and your pull requests.
    case activity
    /// Every fixed block.
    case everything

    public var id: Self { self }

    public var blocks: [GitHubBlock] {
        switch self {
        case .focus: [.reviewRequests, .pullRequests, .status]
        case .glance: [.summary, .status]
        case .triage: [.notifications, .reviewRequests, .issues, .status]
        case .activity: [.contributions, .pullRequests, .status]
        case .everything:
            [.summary, .reviewRequests, .pullRequests, .issues, .notifications, .contributions, .status]
        }
    }
}

/// What a GitHub widget shows in the minimal and bar sizes, where there's room for one value.
public enum GitHubGlance: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Reviews waiting plus your pull requests that need you (failing checks, changes asked for, conflicts).
    case attention
    case reviews
    case pullRequests
    case notifications

    public var id: Self { self }
}

/// How a list block draws its rows.
public enum GitHubRowStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// One line each: state, title, number and age. The most in the least height.
    case singleLine
    /// Two lines each: the title, then the repository, author, checks and reviews.
    case detailed

    public var id: Self { self }
}

/// What a list of pull requests, issues or notifications shows.
public struct GitHubListOptions: Codable, Hashable, Sendable {
    /// What the builder offers for ``maximumRows``.
    public static let rowCountRange = 1...20

    /// Rows in the regular size; compact shows fewer.
    public var maximumRows = 4
    /// Takes no room while there's nothing in it.
    public var hidesWhenEmpty = true
    public var rowStyle = GitHubRowStyle.singleLine

    public init(maximumRows: Int = 4, hidesWhenEmpty: Bool = true, rowStyle: GitHubRowStyle = .singleLine) {
        self.maximumRows = maximumRows
        self.hidesWhenEmpty = hidesWhenEmpty
        self.rowStyle = rowStyle
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GitHubListOptions()
        maximumRows = try container.decode(.maximumRows, or: defaults.maximumRows).clamped(to: Self.rowCountRange)
        hidesWhenEmpty = try container.decode(.hidesWhenEmpty, or: defaults.hidesWhenEmpty)
        rowStyle = container.decodeLeniently(.rowStyle, or: defaults.rowStyle)
    }
}

public struct GitHubReviewOptions: Codable, Hashable, Sendable {
    public var list = GitHubListOptions()
    /// Requests to a team the account is on, as well as to the account itself.
    public var includesTeamRequests = true

    public init(list: GitHubListOptions = .init(), includesTeamRequests: Bool = true) {
        self.list = list
        self.includesTeamRequests = includesTeamRequests
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        list = container.decodeLeniently(.list, or: GitHubListOptions())
        includesTeamRequests = try container.decode(.includesTeamRequests, or: true)
    }
}

public struct GitHubPullRequestOptions: Codable, Hashable, Sendable {
    public var list = GitHubListOptions()
    public var includesDrafts = true

    public init(list: GitHubListOptions = .init(), includesDrafts: Bool = true) {
        self.list = list
        self.includesDrafts = includesDrafts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        list = container.decodeLeniently(.list, or: GitHubListOptions())
        includesDrafts = try container.decode(.includesDrafts, or: true)
    }
}

/// Which issues an Issues block lists.
public enum GitHubIssueScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case assigned
    case created
    case mentioned

    public var id: Self { self }

    /// The search qualifier.
    var qualifier: String {
        switch self {
        case .assigned: "assignee:@me"
        case .created: "author:@me"
        case .mentioned: "mentions:@me"
        }
    }
}

public struct GitHubIssueOptions: Codable, Hashable, Sendable {
    public var list = GitHubListOptions()
    public var scope = GitHubIssueScope.assigned

    public init(list: GitHubListOptions = .init(), scope: GitHubIssueScope = .assigned) {
        self.list = list
        self.scope = scope
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        list = container.decodeLeniently(.list, or: GitHubListOptions())
        scope = container.decodeLeniently(.scope, or: .assigned)
    }
}

public struct GitHubNotificationOptions: Codable, Hashable, Sendable {
    public var list = GitHubListOptions()
    /// Workflow runs finishing. Busy, so off.
    public var includesCIActivity = false
    /// Only threads the account takes part in or is mentioned in, not everything it watches.
    public var participatingOnly = false

    public init(list: GitHubListOptions = .init(), includesCIActivity: Bool = false, participatingOnly: Bool = false) {
        self.list = list
        self.includesCIActivity = includesCIActivity
        self.participatingOnly = participatingOnly
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        list = container.decodeLeniently(.list, or: GitHubListOptions())
        includesCIActivity = try container.decode(.includesCIActivity, or: false)
        participatingOnly = try container.decode(.participatingOnly, or: false)
    }
}

public struct GitHubContributionOptions: Codable, Hashable, Sendable {
    /// What the builder offers for ``weeks``.
    public static let weekRange = 8...53

    /// Weeks of the calendar, ending this week. The cells shrink to fit.
    public var weeks = 20
    public var showsStreak = true

    public init(weeks: Int = 20, showsStreak: Bool = true) {
        self.weeks = weeks
        self.showsStreak = showsStreak
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weeks = try container.decode(.weeks, or: 20).clamped(to: Self.weekRange)
        showsStreak = try container.decode(.showsStreak, or: true)
    }
}

public struct GitHubStatusOptions: Codable, Hashable, Sendable {
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

/// What a Repository block shows: one repository, whatever the widget's repository filter.
public struct GitHubRepositoryBlockOptions: Codable, Hashable, Sendable {
    /// `owner/name`; `nil` until one is chosen.
    public var repository: String?
    /// The default branch's checks and latest commit.
    public var showsBranch = true
    public var showsRelease = true
    /// Open pull requests, issues and stars.
    public var showsCounts = true

    public init(repository: String? = nil) {
        self.repository = repository.flatMap(GitHubSettings.normalizedRepository)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repository = try container.decodeIfPresent(String.self, forKey: .repository).flatMap(
            GitHubSettings.normalizedRepository)
        showsBranch = try container.decode(.showsBranch, or: true)
        showsRelease = try container.decode(.showsRelease, or: true)
        showsCounts = try container.decode(.showsCounts, or: true)
    }
}

/// Each GitHub block's options, side by side, so hiding a block and showing it again loses nothing.
public struct GitHubBlockOptions: Codable, Hashable, Sendable {
    public var reviewRequests = GitHubReviewOptions()
    public var pullRequests = GitHubPullRequestOptions()
    public var issues = GitHubIssueOptions()
    public var notifications = GitHubNotificationOptions()
    public var contributions = GitHubContributionOptions()
    public var status = GitHubStatusOptions()

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reviewRequests = container.decodeLeniently(.reviewRequests, or: GitHubReviewOptions())
        pullRequests = container.decodeLeniently(.pullRequests, or: GitHubPullRequestOptions())
        issues = container.decodeLeniently(.issues, or: GitHubIssueOptions())
        notifications = container.decodeLeniently(.notifications, or: GitHubNotificationOptions())
        contributions = container.decodeLeniently(.contributions, or: GitHubContributionOptions())
        status = container.decodeLeniently(.status, or: GitHubStatusOptions())
    }
}

/// A GitHub widget: whose account, which repositories, how often to ask, and which blocks to show with what options.
public struct GitHubSettings: Codable, Hashable, Sendable {
    /// What the settings offer for ``refresh``, besides manual.
    public static let refreshMinuteChoices = [1, 2, 5, 15, 30]
    /// A hand-edited interval is moved into this.
    public static let refreshMinuteRange = 1...60
    /// The most repositories and owners the filter takes: each is a search qualifier, and GitHub caps a search's
    /// length.
    public static let maximumFilterEntries = 20

    /// The GitHub account it reads; `nil` for the default: the GitHub CLI while it's signed in.
    public var account: AccountID?
    /// Pull requests and issues only from these: `owner/name` for a repository, `owner` for everything a user or
    /// organization owns. Empty for anywhere.
    public var repositories: [String] = [] {
        didSet { repositories = Self.normalizedFilter(repositories) }
    }
    public var refresh = RefreshCadence.minutes(2)
    public var blocks = BlockLayout<GitHubBlock>(shown: GitHubPreset.focus.blocks)
    public var glance = GitHubGlance.attention
    public var blockOptions = GitHubBlockOptions()
    /// Each Repository block's options, by its ID.
    public private(set) var repositoryBlocks: [String: GitHubRepositoryBlockOptions] = [:]

    public init(
        account: AccountID? = nil, repositories: [String] = [], refresh: RefreshCadence = .minutes(2),
        preset: GitHubPreset = .focus, glance: GitHubGlance = .attention
    ) {
        self.account = account
        self.repositories = Self.normalizedFilter(repositories)
        self.refresh = refresh
        blocks = BlockLayout(shown: preset.blocks)
        self.glance = glance
    }

    /// Missing options take their defaults, unknown choices don't fail the whole configuration, and hand-edited
    /// values are moved into what the settings offer.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GitHubSettings()
        account = container.decodeLeniently(.account, or: nil)
        repositories = Self.normalizedFilter(container.decodeLeniently(.repositories, or: [String]()))
        refresh = container.decodeLeniently(.refresh, or: defaults.refresh).clamped(to: Self.refreshMinuteRange)
        blocks = container.decodeLeniently(.blocks, or: defaults.blocks)
        glance = container.decodeLeniently(.glance, or: defaults.glance)
        blockOptions = container.decodeLeniently(.blockOptions, or: defaults.blockOptions)
        // Only the Repository blocks the layout has.
        let stored =
            container.decodeLeniently(.repositoryBlocks, or: [String: LenientElement<GitHubRepositoryBlockOptions>]())
        repositoryBlocks = stored.compactMapValues(\.value).filter { key, _ in
            UUID(uuidString: key).map { blocks.contains(.repository($0)) } ?? false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case account = "accountID"
        case repositories, refresh, blocks, glance, blockOptions, repositoryBlocks
    }

    /// Shows `preset`'s blocks, keeping Repository blocks hidden rather than removing them.
    public mutating func apply(_ preset: GitHubPreset) {
        blocks.showOnly(preset.blocks)
    }

    // MARK: Repository blocks

    /// A Repository block's options; the defaults until it has any.
    public func repositoryOptions(_ id: UUID) -> GitHubRepositoryBlockOptions {
        repositoryBlocks[id.uuidString] ?? GitHubRepositoryBlockOptions()
    }

    public mutating func setRepositoryOptions(_ options: GitHubRepositoryBlockOptions, for id: UUID) {
        guard blocks.contains(.repository(id)) else { return }
        repositoryBlocks[id.uuidString] = options
    }

    /// Adds a Repository block, shown at the end, and returns it.
    @discardableResult
    public mutating func addRepositoryBlock(_ options: GitHubRepositoryBlockOptions = .init()) -> GitHubBlock {
        let id = UUID()
        blocks.add(.repository(id))
        repositoryBlocks[id.uuidString] = options
        return .repository(id)
    }

    /// Removes a Repository block with its options. Fixed blocks can only be hidden.
    public mutating func removeBlock(_ block: GitHubBlock) {
        blocks.remove(block)
        if case .repository(let id) = block { repositoryBlocks[id.uuidString] = nil }
    }

    // MARK: Filter

    /// `owner/name` or `owner`, trimmed, without a github.com prefix or a `.git` suffix; `nil` for anything else.
    public static func normalizedFilterEntry(_ text: String) -> String? {
        var entry = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "www.", "github.com/", "@"] where entry.lowercased().hasPrefix(prefix) {
            entry = String(entry.dropFirst(prefix.count))
        }
        if entry.hasSuffix(".git") { entry = String(entry.dropLast(4)) }
        while entry.hasSuffix("/") { entry = String(entry.dropLast()) }
        let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
        // A pasted link to a pull request or a file still names its repository.
        let kept = parts.prefix(2)
        guard (1...2).contains(kept.count), kept.allSatisfy(isNamePart) else { return nil }
        return kept.joined(separator: "/")
    }

    /// `owner/name` only.
    public static func normalizedRepository(_ text: String) -> String? {
        normalizedFilterEntry(text).flatMap { $0.contains("/") ? $0 : nil }
    }

    /// GitHub's names: letters, digits, `-`, `_` and `.`.
    private static func isNamePart(_ part: Substring) -> Bool {
        !part.isEmpty && part.count <= 100
            && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// Each entry once, ignoring case, in order, and no more than ``maximumFilterEntries``.
    static func normalizedFilter(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        return Array(
            entries.compactMap(normalizedFilterEntry).filter { seen.insert($0.lowercased()).inserted }
                .prefix(maximumFilterEntries))
    }

    /// `repo:a/b user:c`: the filter as search qualifiers, which GitHub ORs together.
    var filterQualifiers: String {
        repositories.map { $0.contains("/") ? "repo:\($0)" : "user:\($0)" }.joined(separator: " ")
    }

    // MARK: Searches

    /// The search each list block runs, with this widget's filter.
    public func search(for block: GitHubBlock) -> GitHubSearch? {
        let base: String
        let kind: GitHub.Item.Kind
        switch block {
        case .reviewRequests:
            let who =
                blockOptions.reviewRequests.includesTeamRequests ? "review-requested:@me" : "user-review-requested:@me"
            base = "is:open is:pr archived:false \(who)"
            kind = .pullRequest
        case .pullRequests:
            base =
                "is:open is:pr archived:false author:@me"
                + (blockOptions.pullRequests.includesDrafts ? "" : " draft:false")
            kind = .pullRequest
        case .issues:
            base = "is:open is:issue archived:false \(blockOptions.issues.scope.qualifier)"
            kind = .issue
        case .summary, .notifications, .contributions, .status, .repository: return nil
        }
        let query = [base, filterQualifiers, "sort:updated-desc"].filter { !$0.isEmpty }.joined(separator: " ")
        return GitHubSearch(query: query, kind: kind)
    }

    /// The query for `search` on github.com, to see every result: `https://github.com/pulls?q=…` or `/issues?q=…`.
    public static func webURL(for search: GitHubSearch) -> URL? {
        var components = URLComponents(string: "https://github.com")!
        components.path = search.kind == .pullRequest ? "/pulls" : "/issues"
        components.queryItems = [URLQueryItem(name: "q", value: search.query)]
        return components.url
    }

    /// The repositories Repository blocks show, whether or not they're shown.
    public var chosenRepositories: [String] {
        blocks.entries.compactMap { entry in
            guard case .repository(let id) = entry.block else { return nil }
            return repositoryOptions(id).repository
        }
    }

    /// What the minimal and bar sizes need, for this glance.
    public func glanceNeeds() -> GitHubNeeds {
        var needs = GitHubNeeds(cadence: refresh)
        switch glance {
        case .attention:
            needs.add(search(for: .reviewRequests), rows: 1)
            needs.add(search(for: .pullRequests), rows: 10)
        case .reviews: needs.add(search(for: .reviewRequests), rows: 1)
        case .pullRequests: needs.add(search(for: .pullRequests), rows: 10)
        case .notifications:
            needs.notifications = GitHubNotificationQuery(
                participatingOnly: blockOptions.notifications.participatingOnly)
        }
        return needs
    }

    /// What the shown blocks need, in the regular and compact sizes.
    public func blockNeeds() -> GitHubNeeds {
        var needs = GitHubNeeds(cadence: refresh)
        for block in blocks.shownBlocks {
            switch block {
            case .summary:
                needs.add(search(for: .reviewRequests), rows: 1)
                needs.add(search(for: .pullRequests), rows: 1)
                needs.add(search(for: .issues), rows: 1)
                needs.notifications = GitHubNotificationQuery(
                    participatingOnly: blockOptions.notifications.participatingOnly)
            case .reviewRequests:
                needs.add(search(for: block), rows: blockOptions.reviewRequests.list.maximumRows)
            case .pullRequests:
                needs.add(search(for: block), rows: blockOptions.pullRequests.list.maximumRows)
            case .issues:
                needs.add(search(for: block), rows: blockOptions.issues.list.maximumRows)
            case .notifications:
                needs.notifications = GitHubNotificationQuery(
                    participatingOnly: blockOptions.notifications.participatingOnly)
            case .contributions:
                needs.contributions = true
            case .status:
                needs.status = true
            case .repository(let id):
                if let name = repositoryOptions(id).repository { needs.repositories.insert(name.lowercased()) }
            }
        }
        return needs
    }
}

/// A search for pull requests or issues.
public struct GitHubSearch: Hashable, Sendable {
    public var query: String
    public var kind: GitHub.Item.Kind

    public init(query: String, kind: GitHub.Item.Kind) {
        self.query = query
        self.kind = kind
    }
}

/// Which notifications to list.
public struct GitHubNotificationQuery: Hashable, Sendable {
    public var participatingOnly: Bool

    public init(participatingOnly: Bool = false) {
        self.participatingOnly = participatingOnly
    }
}

// MARK: - Demand

/// What the GitHub widgets on screen need fetched with one account. Several widgets' needs merge into one request.
public struct GitHubNeeds: Hashable, Sendable {
    /// Each search, with the most results any widget shows from it.
    public var searches: [GitHubSearch: Int] = [:]
    /// `owner/name`, lowercased.
    public var repositories: Set<String> = []
    public var contributions = false
    /// `nil` while nobody shows the inbox. Both kinds merge into all of them.
    public var notifications: GitHubNotificationQuery?
    /// githubstatus.com.
    public var status = false
    public var cadence: RefreshCadence

    public init(cadence: RefreshCadence = .minutes(2)) {
        self.cadence = cadence
    }

    /// Nothing to fetch.
    public var isEmpty: Bool {
        searches.isEmpty && repositories.isEmpty && !contributions && notifications == nil && !status
    }

    /// Whether anything needs the account's GraphQL API, rather than only the status page.
    public var needsGraphQL: Bool { !searches.isEmpty || !repositories.isEmpty || contributions }

    mutating func add(_ search: GitHubSearch?, rows: Int) {
        guard let search else { return }
        searches[search] = max(searches[search] ?? 0, rows)
    }

    public mutating func merge(_ other: GitHubNeeds) {
        searches.merge(other.searches, uniquingKeysWith: max)
        repositories.formUnion(other.repositories)
        contributions = contributions || other.contributions
        switch (notifications, other.notifications) {
        case (nil, let query), (let query, nil): notifications = query
        case (let mine?, let theirs?):
            notifications = GitHubNotificationQuery(
                participatingOnly: mine.participatingOnly && theirs.participatingOnly)
        }
        status = status || other.status
        cadence = cadence.merged(with: other.cadence)
    }
}

/// What the GitHub widgets on screen need.
public struct GitHubDemand: Equatable, Sendable {
    /// What each account needs fetched; accounts nobody shows aren't listed.
    public var accounts: [AccountID: GitHubNeeds]
    /// A GitHub widget is on screen, even one without an account to use yet: the service looks for the CLI for it.
    public var isShown: Bool

    public init(accounts: [AccountID: GitHubNeeds] = [:], isShown: Bool = false) {
        self.accounts = accounts.filter { !$0.value.isEmpty }
        self.isShown = isShown || !self.accounts.isEmpty
    }

    /// Nothing at all unless GitHub widgets are among `kinds`.
    public func limited(to kinds: Set<WidgetKind>) -> GitHubDemand {
        kinds.contains(.gitHub) ? self : GitHubDemand()
    }

    /// What `widget` needs, drawn on `panel`: its glance in bars and minimal columns, its shown blocks otherwise. A
    /// widget without an account it can use fetches nothing, but is still shown.
    public mutating func add(
        _ widget: WidgetInstance, on panel: ShownPanel, in configuration: AppConfiguration, signedIn: Set<AccountID>
    ) {
        guard case .gitHub(let settings) = widget.settings else { return }
        isShown = true
        guard let id = configuration.resolveAccount(settings.account, at: .gitHub, signedIn: signedIn).accountID
        else { return }
        let needs = panel.showsBlocks ? settings.blockNeeds() : settings.glanceNeeds()
        guard !needs.isEmpty else { return }
        if var existing = accounts[id] {
            existing.merge(needs)
            accounts[id] = existing
        } else {
            accounts[id] = needs
        }
    }
}

extension AppConfiguration {
    /// What the GitHub widgets on `panels` need. Previews never count: they show an example, and never run `gh` or
    /// read a token. `signedIn` holds the app sign-ins signed in now, which decide the default account.
    public func gitHubDemand(panels: [ShownPanel], signedIn: Set<AccountID> = []) -> GitHubDemand {
        var demand = GitHubDemand()
        for panel in panels {
            for widget in widgets where widget.isVisible(at: panel.position) {
                demand.add(widget, on: panel, in: self, signedIn: signedIn)
            }
        }
        return demand
    }
}
