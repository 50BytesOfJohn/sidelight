import AppKit
import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let gitHub = WidgetMetadata(
        title: "GitHub",
        systemImage: "arrow.triangle.pull",
        tint: .green,
        summary: "Reviews, pull requests and the inbox",
        details: "Pull requests waiting for your review, your own with their checks, issues, unread notifications, "
            + "repositories and your contributions. Uses the GitHub CLI (gh) when it's signed in, or a token. Built "
            + "from blocks.",
        logo: "GitHubLogo",
        isBeta: true
    )
}

extension GitHubSettings {
    var summary: String {
        let scope =
            switch repositories.count {
            case 0: "Everywhere"
            case 1: repositories[0]
            default: "\(repositories.count) repositories"
            }
        let shown = blocks.shownBlocks.map(title(of:)).joined(separator: ", ")
        return [scope, shown.isEmpty ? "No blocks" : shown].joined(separator: " · ")
    }
}

/// Everything a GitHub widget draws from: what the account's connection fetched, or the sample.
struct GitHubContentData {
    var snapshot: GitHubSnapshot
    var notifications: [GitHub.Notification]?
    var incidents: [GitHub.Incident]
    /// Why the data is old, when it is.
    var footnote: String?
}

// MARK: - Widget

struct GitHubWidgetView: View {
    let settings: GitHubSettings
    let layout: WidgetLayout
    @Environment(GitHubService.self) private var service
    @Environment(AccountStore.self) private var accounts
    @Environment(SettingsNavigator.self) private var navigator
    @Environment(\.isWidgetPreview) private var isPreview

    var body: some View {
        WidgetClock { now in
            if isPreview, previewedConnection?.snapshot.value == nil {
                // A preview of a widget nothing fetched for, such as in the gallery: GitHub isn't asked until a
                // widget is added, so this shows what it looks like.
                GitHubContent(data: .sample(for: settings, now: now), settings: settings, layout: layout, now: now)
            } else {
                AccountGate(reference: settings.account, provider: .gitHub, layout: layout) { id in
                    content(service.connection(id), now: now)
                }
            }
        }
    }

    private var previewedConnection: GitHubConnection? {
        accounts.resolve(settings.account, at: .gitHub).accountID.flatMap(service.connection)
    }

    @ViewBuilder
    private func content(_ connection: GitHubConnection?, now: Date) -> some View {
        let needsGraphQL = (layout.isGlanceable ? settings.glanceNeeds() : settings.blockNeeds()).needsGraphQL
        let problem = connection?.snapshot.problem ?? connection?.notifications.problem
        if let connection, connection.snapshot.value != nil || !needsGraphQL {
            let snapshot = connection.snapshot.value ?? GitHubSnapshot()
            let fetchedAt = connection.snapshot.fetchedAt ?? connection.notifications.fetchedAt
            GitHubContent(
                data: GitHubContentData(
                    snapshot: snapshot, notifications: connection.notifications.value,
                    incidents: service.status.value ?? [],
                    footnote: problem.flatMap { problem in
                        fetchedAt.map { "\(problem.title) · \(Formatting.shortAge(since: $0, now: now)) ago" }
                    }),
                settings: settings, layout: layout, now: now)
        } else if let problem {
            WidgetMessage(
                title: problem.title, detail: problem.advice,
                systemImage: problem.needsSignIn || problem == .cliNotFound
                    ? "person.crop.circle.badge.questionmark" : "exclamationmark.triangle",
                layout: layout,
                action: problem.needsSignIn || problem == .cliNotFound
                    ? WidgetMessage.Action(title: "Open Accounts") { navigator.showAccounts(.gitHub) }
                    : WidgetMessage.Action(title: "Try Again") { service.refreshNow() })
        } else {
            WidgetMessage(title: "Connecting to GitHub…", detail: nil, systemImage: "hourglass", layout: layout)
        }
    }
}

/// The blocks a GitHub widget shows, or its glance.
struct GitHubContent: View {
    let data: GitHubContentData
    let settings: GitHubSettings
    let layout: WidgetLayout
    let now: Date

    var body: some View {
        switch layout {
        case .regular, .compact:
            let blocks = visibleBlocks
            if blocks.isEmpty {
                quiet
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.element) { index, block in
                        if index > 0 {
                            HairlineDivider().padding(.vertical, layout == .regular ? 9 : 6)
                        }
                        GitHubBlockView(block: block, data: data, settings: settings, layout: layout, now: now)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if let footnote = data.footnote {
                        Label(footnote, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.top, 8)
                    }
                }
                .animation(Motion.layout, value: blocks)
            }
        case .minimal, .bar:
            GitHubGlanceView(data: data, settings: settings, isBar: layout == .bar)
        }
    }

    /// Shown blocks with something to show: an empty list that hides when empty takes no room, and the status
    /// block shows only during an incident.
    private var visibleBlocks: [GitHubBlock] {
        settings.blocks.shownBlocks.filter { block in
            switch block {
            case .status:
                return !shownIncidents.isEmpty
            case .reviewRequests:
                return !hidesEmpty(settings.blockOptions.reviewRequests.list, count: count(of: block))
            case .pullRequests:
                return !hidesEmpty(settings.blockOptions.pullRequests.list, count: count(of: block))
            case .issues:
                return !hidesEmpty(settings.blockOptions.issues.list, count: count(of: block))
            case .notifications:
                return !hidesEmpty(settings.blockOptions.notifications.list, count: shownNotifications?.count)
            case .summary, .contributions, .repository:
                return true
            }
        }
    }

    private func hidesEmpty(_ options: GitHubListOptions, count: Int?) -> Bool {
        options.hidesWhenEmpty && count == 0
    }

    private func count(of block: GitHubBlock) -> Int? {
        data.snapshot.result(settings.search(for: block))?.totalCount
    }

    private var shownNotifications: [GitHub.Notification]? {
        data.notifications?.filtered(settings.blockOptions.notifications)
    }

    private var shownIncidents: [GitHub.Incident] {
        data.incidents.filter { settings.blockOptions.status.showsMaintenance || !$0.isMaintenance }
    }

    /// Every list is empty and hides itself.
    private var quiet: some View {
        HStack(spacing: 6) {
            WidgetIcon(metadata: .gitHub, size: 11).foregroundStyle(.secondary)
            Text(
                settings.blocks.shownBlocks.isEmpty ? "Choose blocks in this widget's builder." : "All clear on GitHub")
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green.opacity(0.8))
        }
        .font(.system(size: layout == .regular ? 11 : 10))
        .foregroundStyle(.secondary)
        .help("No reviews, pull requests, issues or notifications waiting")
    }
}

extension [GitHub.Notification] {
    /// What a Notifications block lists, given its options.
    func filtered(_ options: GitHubNotificationOptions) -> [GitHub.Notification] {
        options.includesCIActivity ? self : filter { !$0.isCIActivity }
    }
}

// MARK: - Glance

/// The one value the minimal and bar sizes show.
private struct GitHubGlanceView: View {
    let data: GitHubContentData
    let settings: GitHubSettings
    let isBar: Bool

    private var reviews: Int? { data.snapshot.result(settings.search(for: .reviewRequests))?.totalCount }
    private var pullRequests: GitHub.SearchResult? { data.snapshot.result(settings.search(for: .pullRequests)) }
    private var needingYou: Int? { pullRequests?.items.count(where: \.needsAuthor) }
    private var unread: Int? { data.notifications?.filtered(settings.blockOptions.notifications).count }

    /// The number the glance badges, and its color.
    private var count: (Int, Color)? {
        switch settings.glance {
        case .attention:
            guard let reviews else { return nil }
            let failing = needingYou ?? 0
            return (reviews + failing, failing > 0 ? .red : .blue)
        case .reviews: return reviews.map { ($0, .blue) }
        case .pullRequests:
            return pullRequests.map { ($0.totalCount, (needingYou ?? 0) > 0 ? .red : .green) }
        case .notifications: return unread.map { ($0, .blue) }
        }
    }

    var body: some View {
        Group {
            if isBar { bar } else { minimal }
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
        .opens { if let url = webURL { NSWorkspace.shared.open(url) } }
    }

    private var minimal: some View {
        let count = count
        return WidgetIcon(metadata: .gitHub, size: 18)
            .foregroundStyle(count.map { $0.0 > 0 } ?? false ? .primary : .secondary)
            .frame(width: 28, height: 26)
            .overlay(alignment: .topTrailing) {
                if let (value, color) = count, value > 0 {
                    CountBadge(count: value, color: color)
                        .offset(x: 6, y: -5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(Motion.snappy, value: count?.0)
    }

    private var bar: some View {
        HStack(spacing: 6) {
            WidgetIcon(metadata: .gitHub, size: 11)
            Text(barText).lineLimit(1).contentTransition(.numericText())
        }
        .font(.system(size: 11, weight: .medium))
    }

    private var barText: String {
        switch settings.glance {
        case .attention:
            guard let reviews else { return "GitHub" }
            let parts = [
                reviews > 0 ? plural(reviews, "review") : nil,
                (needingYou ?? 0) > 0 ? "\(needingYou ?? 0) need you" : nil,
            ].compactMap(\.self)
            return parts.isEmpty ? "All clear" : parts.joined(separator: " · ")
        case .reviews: return reviews.map { plural($0, "review") } ?? "GitHub"
        case .pullRequests: return pullRequests.map { plural($0.totalCount, "open PR") } ?? "GitHub"
        case .notifications: return unread.map { $0 == 0 ? "Inbox zero" : "\($0) unread" } ?? "GitHub"
        }
    }

    private var help: String {
        var lines: [String] = []
        if let reviews { lines.append(plural(reviews, "review request")) }
        if let pullRequests {
            lines.append(plural(pullRequests.totalCount, "open pull request"))
            if let needingYou, needingYou > 0 { lines.append("\(needingYou) need you: checks, changes or conflicts") }
        }
        if let unread { lines.append("\(unread) unread notifications") }
        return lines.isEmpty ? "GitHub" : lines.joined(separator: "\n")
    }

    private var webURL: URL? {
        switch settings.glance {
        case .attention, .reviews: settings.search(for: .reviewRequests).flatMap(GitHubSettings.webURL(for:))
        case .pullRequests: settings.search(for: .pullRequests).flatMap(GitHubSettings.webURL(for:))
        case .notifications: GitHubAPI.notificationsWebsite
        }
    }
}

/// `1 review`, `3 reviews`.
func plural(_ count: Int, _ noun: String) -> String {
    count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
}

// MARK: - Sample

extension GitHubContentData {
    /// What the widget looks like before it's connected: an imaginary team's week.
    /// The sample answers this widget's own searches and repositories, whatever its options.
    static func sample(for settings: GitHubSettings, now: Date) -> GitHubContentData {
        func item(
            _ kind: GitHub.Item.Kind, _ repository: String, _ number: Int, _ title: String, author: String,
            hoursAgo: Double
        ) -> GitHub.Item {
            var item = GitHub.Item(
                kind: kind, repository: repository, number: number, title: title,
                url: URL(string: "https://github.com/\(repository)/\(kind == .issue ? "issues" : "pull")/\(number)"),
                author: author, createdAt: now.addingTimeInterval(-hoursAgo * 7200),
                updatedAt: now.addingTimeInterval(-hoursAgo * 3600))
            item.comments = number % 5
            return item
        }
        var reviews = [
            item(.pullRequest, "acme/storefront", 482, "Cache product search results", author: "ada", hoursAgo: 0.4),
            item(.pullRequest, "acme/api", 1290, "Add rate limits to the public API", author: "lin", hoursAgo: 5),
        ]
        reviews[0].checks = .success
        reviews[0].additions = 120
        reviews[0].deletions = 34
        reviews[1].checks = .pending
        var mine = [
            item(.pullRequest, "acme/storefront", 479, "New checkout flow", author: "you", hoursAgo: 2),
            item(.pullRequest, "acme/worker", 77, "Retry failed webhooks with backoff", author: "you", hoursAgo: 20),
            item(.pullRequest, "acme/api", 1284, "Drop the v1 endpoints", author: "you", hoursAgo: 50),
        ]
        mine[0].checks = .failure
        mine[1].checks = .success
        mine[1].reviewDecision = .approved
        mine[2].isDraft = true
        mine[2].checks = .pending
        var issues = [
            item(.issue, "acme/storefront", 470, "Cart total rounds the wrong way", author: "sam", hoursAgo: 8),
            item(.issue, "acme/api", 1201, "Document pagination", author: "lin", hoursAgo: 70),
        ]
        issues[0].labels = [GitHub.Label(name: "bug", color: "d73a4a")]
        var snapshot = GitHubSnapshot(login: "you")
        for (block, items) in [(GitHubBlock.reviewRequests, reviews), (.pullRequests, mine), (.issues, issues)] {
            if let search = settings.search(for: block) {
                snapshot.searches[search] = GitHub.SearchResult(totalCount: items.count, items: items)
            }
        }
        for name in settings.chosenRepositories {
            snapshot.repositories[name.lowercased()] = sampleRepository(name, now: now)
        }
        snapshot.contributions = sampleContributions(now: now)
        let notifications = [
            GitHub.Notification(
                id: "1", title: "Cache product search results", subject: .pullRequest, reason: "review_requested",
                repository: "acme/storefront", updatedAt: now.addingTimeInterval(-1500)),
            GitHub.Notification(
                id: "2", title: "v2.4.0", subject: .release, reason: "subscribed", repository: "acme/api",
                updatedAt: now.addingTimeInterval(-4 * 3600)),
            GitHub.Notification(
                id: "3", title: "Cart total rounds the wrong way", subject: .issue, reason: "mention",
                repository: "acme/storefront", updatedAt: now.addingTimeInterval(-9 * 3600)),
        ]
        return GitHubContentData(snapshot: snapshot, notifications: notifications, incidents: [], footnote: nil)
    }

    private static func sampleRepository(_ name: String, now: Date) -> GitHub.Repository {
        var repository = GitHub.Repository(name: name, url: URL(string: "https://github.com/\(name)"))
        repository.stars = 1284
        repository.openPullRequests = 6
        repository.openIssues = 23
        repository.defaultBranch = "main"
        repository.branchChecks = .success
        repository.lastCommitTitle = "Merge pull request #479 from acme/checkout"
        repository.lastCommitDate = now.addingTimeInterval(-3 * 3600)
        repository.latestRelease = GitHub.Release(tag: "v2.4.0", publishedAt: now.addingTimeInterval(-4 * 86_400))
        return repository
    }

    /// A believable year: busier on weekdays, quieter lately.
    private static func sampleContributions(now: Date) -> GitHub.Contributions {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: now)
        // Back to the Sunday 52 weeks ago, as GitHub's calendar starts.
        let weekday = calendar.component(.weekday, from: today) - 1
        let start = calendar.date(byAdding: .day, value: -(52 * 7 + weekday), to: today) ?? today
        var days: [GitHub.Contributions.Day] = []
        var date = start
        var index = 0
        while date <= today {
            let day = calendar.component(.weekday, from: date)
            let weekend = day == 1 || day == 7
            // A fixed pattern rather than randomness, so the preview doesn't change between redraws.
            let wave = (index * 7919 + index / 7 * 104_729) % 11
            let count = weekend ? max(0, wave - 8) : max(0, wave - 2)
            let level = count == 0 ? 0 : min(4, 1 + count / 3)
            days.append(.init(date: date.formatted(.iso8601.year().month().day()), count: count, level: level))
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? today.addingTimeInterval(86_400)
            index += 1
        }
        return GitHub.Contributions(total: days.reduce(0) { $0 + $1.count }, days: days)
    }
}
