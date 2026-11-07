import AppKit
import SidelightCore
import SwiftUI

/// One block of a GitHub widget.
struct GitHubBlockView: View {
    let block: GitHubBlock
    let data: GitHubContentData
    let settings: GitHubSettings
    let layout: WidgetLayout
    let now: Date

    private var isCompact: Bool { layout == .compact }

    var body: some View {
        let options = settings.blockOptions
        switch block {
        case .summary:
            GitHubSummaryBlock(data: data, settings: settings, isCompact: isCompact)
        case .reviewRequests:
            itemList(block, title: "Review requests", empty: "No reviews waiting", options: options.reviewRequests.list)
        case .pullRequests:
            itemList(
                block, title: "Your pull requests", empty: "No open pull requests", options: options.pullRequests.list)
        case .issues:
            itemList(block, title: issuesTitle, empty: "No open issues", options: options.issues.list)
        case .notifications:
            GitHubNotificationsBlock(
                notifications: data.notifications?.filtered(options.notifications), options: options.notifications.list,
                isCompact: isCompact, now: now)
        case .contributions:
            GitHubContributionsBlock(
                contributions: data.snapshot.contributions, options: options.contributions, isCompact: isCompact)
        case .status:
            GitHubStatusBlock(
                incidents: data.incidents.filter { options.status.showsMaintenance || !$0.isMaintenance },
                isCompact: isCompact)
        case .repository(let id):
            let chosen = settings.repositoryOptions(id)
            GitHubRepositoryBlock(
                options: chosen, repository: chosen.repository.flatMap { data.snapshot.repository($0) },
                isCompact: isCompact, now: now)
        }
    }

    private var issuesTitle: String {
        switch settings.blockOptions.issues.scope {
        case .assigned: "Assigned issues"
        case .created: "Your issues"
        case .mentioned: "Mentions"
        }
    }

    private func itemList(_ block: GitHubBlock, title: String, empty: String, options: GitHubListOptions) -> some View {
        let search = settings.search(for: block)
        return GitHubItemsBlock(
            title: title, empty: empty, result: data.snapshot.result(search),
            webURL: search.flatMap(GitHubSettings.webURL(for:)), options: options,
            role: block == .pullRequests ? .author : .other,
            showsRepository: settings.repositories.count != 1, isCompact: isCompact, now: now)
    }
}

// MARK: - Lists

/// A block's name in small capitals, with how many there are; clicking it opens them all on github.com.
private struct GitHubBlockHeader: View {
    let title: String
    let count: Int?
    let url: URL?
    let isCompact: Bool

    var body: some View {
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title.uppercased())
                    .font(.system(size: isCompact ? 9 : 9.5, weight: .semibold))
                    .tracking(0.7)
                Spacer(minLength: 4)
                if let count {
                    Text(count.formatted())
                        .font(.system(size: isCompact ? 9.5 : 10, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(count)))
                }
            }
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .help(url == nil ? title : "Open on GitHub")
    }
}

/// Whose pull requests a list shows, which decides what its rows point out.
enum GitHubItemRole {
    /// The account's own: what needs it, like failing checks.
    case author
    /// Someone else's, or issues.
    case other
}

private struct GitHubItemsBlock: View {
    let title: String
    let empty: String
    /// `nil` until fetched.
    let result: GitHub.SearchResult?
    let webURL: URL?
    let options: GitHubListOptions
    let role: GitHubItemRole
    let showsRepository: Bool
    let isCompact: Bool
    let now: Date

    var body: some View {
        let limit = isCompact ? min(options.maximumRows, 3) : options.maximumRows
        let items = Array((result?.items ?? []).prefix(limit))
        VStack(alignment: .leading, spacing: isCompact ? 3 : 5) {
            GitHubBlockHeader(title: title, count: result?.totalCount, url: webURL, isCompact: isCompact)
            if result == nil {
                Text("Loading…").font(.system(size: isCompact ? 10 : 11)).foregroundStyle(.secondary)
            } else if items.isEmpty {
                Text(empty).font(.system(size: isCompact ? 10 : 11)).foregroundStyle(.tertiary)
            }
            ForEach(items) { item in
                GitHubItemRow(
                    item: item, role: role, style: isCompact ? .singleLine : options.rowStyle,
                    showsRepository: showsRepository, isCompact: isCompact, now: now)
            }
        }
        .animation(Motion.gentle, value: items.map(\.id))
    }
}

/// A pull request's or issue's glyph: what state it's in, at a glance.
private struct GitHubItemGlyph: View {
    let item: GitHub.Item
    let role: GitHubItemRole
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size + 3)
            .help(meaning)
    }

    private var symbol: String {
        if item.kind == .issue { return "smallcircle.filled.circle" }
        if item.isDraft { return "pencil.circle" }
        if item.checks == .failure { return "xmark.circle.fill" }
        if role == .author {
            if item.reviewDecision == .changesRequested { return "arrow.uturn.backward.circle.fill" }
            if item.hasConflicts { return "exclamationmark.triangle.fill" }
            if item.isReadyToMerge { return "checkmark.circle.fill" }
        }
        if item.checks == .pending { return "circle.dotted.circle" }
        return "arrow.triangle.pull"
    }

    private var color: Color {
        if item.kind == .issue { return .green }
        if item.isDraft { return .secondary }
        if item.checks == .failure { return .red }
        if role == .author {
            if item.reviewDecision == .changesRequested || item.hasConflicts { return .orange }
            if item.isReadyToMerge { return .green }
        }
        if item.checks == .pending { return .yellow }
        return .green
    }

    private var meaning: String {
        if item.kind == .issue { return "Open issue" }
        return [
            item.isDraft ? "Draft" : nil,
            item.checks.map {
                switch $0 {
                case .success: "Checks passed"
                case .failure: "Checks failed"
                case .pending: "Checks running"
                }
            },
            item.reviewDecision.map {
                switch $0 {
                case .approved: "Approved"
                case .changesRequested: "Changes requested"
                case .reviewRequired: "Review required"
                }
            },
            item.hasConflicts ? "Has conflicts" : nil,
        ].compactMap(\.self).joined(separator: " · ")
    }
}

private struct GitHubItemRow: View {
    let item: GitHub.Item
    let role: GitHubItemRole
    let style: GitHubRowStyle
    let showsRepository: Bool
    let isCompact: Bool
    let now: Date

    var body: some View {
        Button {
            if let url = item.url { NSWorkspace.shared.open(url) }
        } label: {
            Group {
                switch style {
                case .singleLine: singleLine
                case .detailed: detailed
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight(vertical: isCompact ? 1.5 : 2.5)
        .contextMenu { GitHubItemMenu(item: item) }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
        .accessibilityHint("Opens it on GitHub")
    }

    private var singleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: isCompact ? 5 : 6) {
            GitHubItemGlyph(item: item, role: role, size: isCompact ? 9 : 10)
            Text(item.title)
                .font(.system(size: isCompact ? 11 : 12, weight: .medium))
                .foregroundStyle(item.isDraft ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if showsRepository && !isCompact {
                Text(item.repositoryName).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1)
                    .layoutPriority(-1)
            }
            age
        }
    }

    private var detailed: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            GitHubItemGlyph(item: item, role: role, size: 11)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(item.isDraft ? .secondary : .primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    age
                }
                HStack(spacing: 5) {
                    Text(subtitle).lineLimit(1)
                    Spacer(minLength: 2)
                    badges
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
    }

    /// `storefront #482 · ada`
    private var subtitle: String {
        let place = showsRepository ? "\(item.repositoryName) #\(item.number)" : "#\(item.number)"
        let author = role == .author ? nil : item.author
        return [place, author].compactMap(\.self).joined(separator: " · ")
    }

    @ViewBuilder
    private var badges: some View {
        if item.comments > 0 {
            Label("\(item.comments)", systemImage: "bubble.left").labelStyle(TightLabelStyle())
        }
        if let additions = item.additions, let deletions = item.deletions, additions + deletions > 0 {
            HStack(spacing: 2) {
                Text("+\(Formatting.compactCount(Int64(additions)))").foregroundStyle(.green)
                Text("−\(Formatting.compactCount(Int64(deletions)))").foregroundStyle(.red)
            }
            .monospacedDigit()
        }
        if let label = item.labels.first {
            GitHubLabelChip(label: label)
        }
    }

    private var age: some View {
        Text(item.updatedAt.map { Formatting.shortAge(since: $0, now: now) } ?? "")
            .font(.system(size: isCompact ? 9.5 : 10))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var help: String {
        var lines = ["\(item.repository)#\(item.number): \(item.title)"]
        let details = [
            item.author.map { "by \($0)" },
            item.updatedAt.map { "updated \($0.formatted(.relative(presentation: .named)))" },
        ].compactMap(\.self)
        if !details.isEmpty { lines.append(details.joined(separator: ", ")) }
        if item.kind == .pullRequest {
            let state = [
                item.isDraft ? "draft" : nil,
                item.checks.map { "checks \($0 == .success ? "passed" : $0 == .failure ? "failed" : "running")" },
                item.reviewDecision.map {
                    $0 == .approved ? "approved" : $0 == .changesRequested ? "changes requested" : "review required"
                },
                item.hasConflicts ? "has conflicts" : nil,
            ].compactMap(\.self)
            if !state.isEmpty { lines.append(state.joined(separator: ", ")) }
        }
        return lines.joined(separator: "\n")
    }
}

/// An issue label, in its color.
private struct GitHubLabelChip: View {
    let label: GitHub.Label

    var body: some View {
        let color = label.color.flatMap(labelColor) ?? .secondary
        Text(label.name)
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 0.5)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.16)))
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.5))
    }
}

/// What a pull request's or issue's menu offers: open it, and copy what a terminal needs.
private struct GitHubItemMenu: View {
    let item: GitHub.Item

    var body: some View {
        if let url = item.url {
            Button("Open on GitHub", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
            Button("Copy Link", systemImage: "link") { copy(url.absoluteString) }
        }
        Button("Copy \(item.repository)#\(item.number)", systemImage: "number") {
            copy("\(item.repository)#\(item.number)")
        }
        if item.kind == .pullRequest {
            Divider()
            if let branch = item.headBranch {
                Button("Copy Branch Name", systemImage: "arrow.triangle.branch") { copy(branch) }
            }
            Button("Copy Checkout Command", systemImage: "terminal") {
                copy("gh pr checkout \(item.number) --repo \(item.repository)")
            }
        }
        Divider()
        Button("Open \(item.repository)", systemImage: "folder") {
            if let url = URL(string: "https://github.com/\(item.repository)") { NSWorkspace.shared.open(url) }
        }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Notifications

private struct GitHubNotificationsBlock: View {
    /// `nil` until fetched.
    let notifications: [GitHub.Notification]?
    let options: GitHubListOptions
    let isCompact: Bool
    let now: Date

    var body: some View {
        let limit = isCompact ? min(options.maximumRows, 3) : options.maximumRows
        let shown = Array((notifications ?? []).prefix(limit))
        VStack(alignment: .leading, spacing: isCompact ? 3 : 5) {
            GitHubBlockHeader(
                title: "Inbox", count: notifications.map(\.count), url: GitHubAPI.notificationsWebsite,
                isCompact: isCompact)
            if notifications == nil {
                Text("Loading…").font(.system(size: isCompact ? 10 : 11)).foregroundStyle(.secondary)
            } else if shown.isEmpty {
                Text("Inbox zero").font(.system(size: isCompact ? 10 : 11)).foregroundStyle(.tertiary)
            }
            ForEach(shown) { notification in
                GitHubNotificationRow(
                    notification: notification, isDetailed: !isCompact && options.rowStyle == .detailed,
                    isCompact: isCompact, now: now)
            }
        }
        .animation(Motion.gentle, value: shown.map(\.id))
    }
}

private struct GitHubNotificationRow: View {
    let notification: GitHub.Notification
    let isDetailed: Bool
    let isCompact: Bool
    let now: Date

    var body: some View {
        Button {
            if let url = notification.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: isCompact ? 5 : 6) {
                Image(systemName: symbol)
                    .font(.system(size: isCompact ? 9 : 10, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: isCompact ? 12 : 13)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(notification.title)
                            .font(.system(size: isCompact ? 11 : 12, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(notification.updatedAt.map { Formatting.shortAge(since: $0, now: now) } ?? "")
                            .font(.system(size: isCompact ? 9.5 : 10))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    if isDetailed {
                        Text("\(notification.repository) · \(reason)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight(vertical: isCompact ? 1.5 : 2.5)
        .contextMenu {
            if let url = notification.url {
                Button("Open on GitHub", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
                Button("Copy Link", systemImage: "link") { copy(url.absoluteString) }
            }
            Button("Open Inbox", systemImage: "tray") { NSWorkspace.shared.open(GitHubAPI.notificationsWebsite) }
        }
        .help("\(notification.repository): \(notification.title)\n\(reason)")
    }

    private var symbol: String {
        switch notification.subject {
        case .pullRequest: "arrow.triangle.pull"
        case .issue: "smallcircle.filled.circle"
        case .release: "tag"
        case .discussion: "bubble.left.and.bubble.right"
        case .commit: "point.topleft.down.to.point.bottomright.curvepath"
        case .checkSuite: "gearshape"
        case .other: "bell"
        }
    }

    /// `Review requested`, `Mentioned`…
    private var reason: String {
        switch notification.reason {
        case "review_requested": "Review requested"
        case "mention": "Mentioned"
        case "team_mention": "Team mentioned"
        case "assign": "Assigned"
        case "author": "You opened it"
        case "comment": "Commented"
        case "ci_activity": "Workflow run"
        case "state_change": "State changed"
        case "subscribed": "Watching"
        case "security_alert": "Security alert"
        case "manual": "Subscribed"
        default: notification.reason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

// MARK: - Summary

/// One line of counts, each opening its list on github.com.
private struct GitHubSummaryBlock: View {
    let data: GitHubContentData
    let settings: GitHubSettings
    let isCompact: Bool

    var body: some View {
        HStack(spacing: isCompact ? 8 : 12) {
            if !isCompact {
                WidgetIcon(metadata: .gitHub, size: 12).foregroundStyle(.secondary)
            }
            chip(.reviewRequests, systemImage: "eye", title: "review requests")
            chip(.pullRequests, systemImage: "arrow.triangle.pull", title: "open pull requests")
            chip(.issues, systemImage: "smallcircle.filled.circle", title: "issues")
            let unread = data.notifications?.filtered(settings.blockOptions.notifications).count
            GitHubCountChip(
                systemImage: "bell", count: unread, color: .blue, title: "unread notifications",
                url: GitHubAPI.notificationsWebsite, isCompact: isCompact)
            Spacer(minLength: 0)
        }
    }

    private func chip(_ block: GitHubBlock, systemImage: String, title: String) -> some View {
        let search = settings.search(for: block)
        let result = data.snapshot.result(search)
        let needsYou = block == .pullRequests && (result?.items.contains(where: \.needsAuthor) ?? false)
        return GitHubCountChip(
            systemImage: systemImage, count: result?.totalCount, color: needsYou ? .red : .primary, title: title,
            url: search.flatMap(GitHubSettings.webURL(for:)), isCompact: isCompact)
    }
}

private struct GitHubCountChip: View {
    let systemImage: String
    let count: Int?
    let color: Color
    let title: String
    let url: URL?
    let isCompact: Bool

    var body: some View {
        let value = count ?? 0
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: isCompact ? 9.5 : 10.5, weight: .semibold))
                Text(count.map { $0.formatted() } ?? "–")
                    .font(.system(size: isCompact ? 11 : 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(value)))
            }
            .foregroundStyle(value > 0 ? AnyShapeStyle(color) : AnyShapeStyle(.tertiary))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(count.map(String.init) ?? "No") \(title)")
    }
}

// MARK: - Contributions

/// The contribution calendar: a column per week, a cell per day, darker for busier days.
private struct GitHubContributionsBlock: View {
    let contributions: GitHub.Contributions?
    let options: GitHubContributionOptions
    let isCompact: Bool

    var body: some View {
        let weeks = contributions?.weeks(isCompact ? min(options.weeks, 16) : options.weeks) ?? []
        VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let contributions {
                    Text(contributions.total.formatted())
                        .font(.system(size: isCompact ? 11 : 12.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(isCompact ? "this year" : "contributions this year")
                        .font(.system(size: isCompact ? 9.5 : 10.5))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Loading contributions…").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if options.showsStreak, let streak = contributions?.currentStreak, streak > 0 {
                    Label("\(streak)d", systemImage: "flame.fill")
                        .labelStyle(TightLabelStyle())
                        .font(.system(size: isCompact ? 9.5 : 10.5, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help(
                            "\(streak)-day streak. Longest this year: \(contributions?.longestStreak ?? streak) days")
                }
            }
            if !weeks.isEmpty {
                GitHubCalendarGrid(weeks: weeks)
                    .aspectRatio(CGFloat(weeks.count) / 7, contentMode: .fit)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            if let url = URL(string: "https://github.com/") { NSWorkspace.shared.open(url) }
        }
    }
}

private struct GitHubCalendarGrid: View {
    let weeks: [[GitHub.Contributions.Day]]

    var body: some View {
        Canvas { context, size in
            let columns = CGFloat(weeks.count)
            let pitch = min(size.width / columns, size.height / 7)
            let gap = max(1, pitch * 0.18)
            let cell = pitch - gap
            for (column, week) in weeks.enumerated() {
                for (row, day) in week.enumerated() {
                    let rect = CGRect(
                        x: CGFloat(column) * pitch, y: CGFloat(row) * pitch, width: cell, height: cell)
                    let path = Path(roundedRect: rect, cornerRadius: cell * 0.25)
                    context.fill(path, with: .color(Self.color(level: day.level)))
                }
            }
        }
        .accessibilityLabel("Contribution calendar")
    }

    static func color(level: Int) -> Color {
        switch level {
        case 0: Color.primary.opacity(0.07)
        case 1: Color.green.opacity(0.35)
        case 2: Color.green.opacity(0.55)
        case 3: Color.green.opacity(0.78)
        default: Color.green
        }
    }
}

// MARK: - Repository

private struct GitHubRepositoryBlock: View {
    let options: GitHubRepositoryBlockOptions
    /// `nil` before it's fetched, `.some(nil)` when GitHub can't find it.
    let repository: GitHub.Repository??
    let isCompact: Bool
    let now: Date

    var body: some View {
        if let name = options.repository {
            switch repository {
            case .some(.some(let repository)): content(repository)
            case .some(.none):
                Text("GitHub can't find \(name), or this account can't see it.")
                    .font(.system(size: isCompact ? 10 : 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .none:
                Text("Loading \(name)…").font(.system(size: isCompact ? 10 : 11)).foregroundStyle(.secondary)
            }
        } else {
            Text("Choose a repository for this block in the builder.")
                .font(.system(size: isCompact ? 10 : 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func content(_ repository: GitHub.Repository) -> some View {
        VStack(alignment: .leading, spacing: isCompact ? 2 : 4) {
            HStack(spacing: 6) {
                Image(systemName: repository.isPrivate ? "lock" : "book.closed")
                    .font(.system(size: isCompact ? 9.5 : 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(repository.name)
                    .font(.system(size: isCompact ? 11.5 : 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                if options.showsBranch, let checks = repository.branchChecks {
                    GitHubChecksBadge(checks: checks, branch: repository.defaultBranch, isCompact: isCompact)
                }
            }
            if options.showsBranch, !isCompact, let title = repository.lastCommitTitle {
                HStack(spacing: 4) {
                    Text(title).lineLimit(1)
                    Spacer(minLength: 4)
                    if let date = repository.lastCommitDate {
                        Text(Formatting.shortAge(since: date, now: now)).monospacedDigit().fixedSize()
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            if options.showsCounts || options.showsRelease {
                HStack(spacing: isCompact ? 8 : 10) {
                    if options.showsCounts {
                        stat("arrow.triangle.pull", repository.openPullRequests, "open pull requests")
                        stat("smallcircle.filled.circle", repository.openIssues, "open issues")
                        if !isCompact { stat("star", repository.stars, "stars") }
                    }
                    Spacer(minLength: 0)
                    if options.showsRelease, let release = repository.latestRelease {
                        Label(release.tag, systemImage: "tag")
                            .labelStyle(TightLabelStyle())
                            .lineLimit(1)
                            .help(
                                [
                                    "Latest release \(release.tag)",
                                    release.publishedAt?.formatted(.relative(presentation: .named)),
                                ].compactMap(\.self).joined(separator: ", "))
                    }
                }
                .font(.system(size: isCompact ? 9.5 : 10))
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .onTapGesture { if let url = repository.url { NSWorkspace.shared.open(url) } }
        .contextMenu {
            if let url = repository.url {
                Button("Open on GitHub", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
                Button("Pull Requests", systemImage: "arrow.triangle.pull") {
                    NSWorkspace.shared.open(url.appending(path: "pulls"))
                }
                Button("Issues", systemImage: "smallcircle.filled.circle") {
                    NSWorkspace.shared.open(url.appending(path: "issues"))
                }
                Button("Actions", systemImage: "gearshape.2") {
                    NSWorkspace.shared.open(url.appending(path: "actions"))
                }
                Divider()
                Button("Copy Clone Command", systemImage: "terminal") { copy("gh repo clone \(repository.name)") }
            }
        }
        .help("Open \(repository.name) on GitHub")
    }

    private func stat(_ systemImage: String, _ value: Int, _ title: String) -> some View {
        Label(Formatting.compactCount(Int64(value)), systemImage: systemImage)
            .labelStyle(TightLabelStyle())
            .monospacedDigit()
            .help("\(value.formatted()) \(title)")
    }
}

private struct GitHubChecksBadge: View {
    let checks: GitHub.CheckState
    let branch: String?
    let isCompact: Bool

    var body: some View {
        let (symbol, color, title): (String, Color, String) =
            switch checks {
            case .success: ("checkmark.circle.fill", .green, "Passing")
            case .failure: ("xmark.circle.fill", .red, "Failing")
            case .pending: ("circle.dotted.circle", .yellow, "Running")
            }
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if !isCompact { Text(title) }
        }
        .font(.system(size: isCompact ? 9.5 : 10, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, isCompact ? 0 : 6)
        .padding(.vertical, isCompact ? 0 : 2)
        .background(Capsule().fill(color.opacity(isCompact ? 0 : 0.14)))
        .help("Checks on \(branch ?? "the default branch"): \(title.lowercased())")
    }
}

// MARK: - Status

private struct GitHubStatusBlock: View {
    let incidents: [GitHub.Incident]
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
            ForEach(incidents.prefix(3)) { incident in
                Button {
                    NSWorkspace.shared.open(incident.url ?? GitHubAPI.statusWebsite)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(
                            systemName: incident.isMaintenance
                                ? "wrench.and.screwdriver.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(incident.isMaintenance ? Color.blue : color(incident))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(incident.title)
                                .font(.system(size: isCompact ? 10.5 : 11.5, weight: .medium))
                                .lineLimit(2)
                            if !isCompact, let status = incident.status {
                                Text("GitHub · \(status.replacingOccurrences(of: "_", with: " ").capitalized)")
                                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: isCompact ? 10 : 11))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Open githubstatus.com")
            }
        }
    }

    private func color(_ incident: GitHub.Incident) -> Color {
        incident.impact == "critical" || incident.impact == "major" ? .red : .orange
    }
}

/// `d73a4a`, as GitHub gives a label's color.
private func labelColor(_ hex: String) -> Color? {
    RGBAColor(hex: hex).map { Color($0) }
}
