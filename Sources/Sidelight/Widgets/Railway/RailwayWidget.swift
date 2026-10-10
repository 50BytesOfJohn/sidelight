import AppKit
import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let railway = WidgetMetadata(
        title: "Railway",
        systemImage: "tram.fill",
        tint: .purple,
        summary:
            "Your Railway services and their deploys, the bill so far, and Railway's incidents. Built from blocks.",
        logo: "RailwayLogo",
        isBeta: true
    )
}

extension RailwaySettings {
    var summary: String {
        let scope = projectName ?? (projectID == nil ? "All projects" : "One project")
        let shown = blocks.shownBlocks.map(title(of:)).joined(separator: ", ")
        return [scope, environmentName, shown.isEmpty ? "No blocks" : shown].compactMap(\.self).joined(separator: " · ")
    }
}

extension Railway.Health {
    var color: Color {
        switch self {
        case .failing: .red
        case .deploying: .blue
        case .running: .green
        case .sleeping, .inactive: .secondary
        }
    }
}

extension Railway.DeploymentStatus {
    var title: String {
        switch self {
        case .queued: "Queued"
        case .waiting: "Waiting"
        case .needsApproval: "Needs approval"
        case .initializing: "Initializing"
        case .building: "Building"
        case .deploying: "Deploying"
        case .success: "Online"
        case .sleeping: "Asleep"
        case .crashed: "Crashed"
        case .failed: "Failed"
        case .removing: "Removing"
        case .removed: "Removed"
        case .skipped: "Skipped"
        case .other(let value): value.capitalized
        }
    }
}

extension RailwayServiceRow {
    var statusTitle: String {
        guard let deployment else { return "No deploys" }
        return health == .sleeping ? "Asleep" : deployment.status.title
    }
}

extension RailwayOverview {
    /// `All online`, `1 failing`, `2 deploying`.
    var healthTitle: String {
        if rows.isEmpty { return "No services" }
        let failing = count(.failing)
        if failing > 0 { return "\(failing) failing" }
        let deploying = count(.deploying)
        if deploying > 0 { return "\(deploying) deploying" }
        let (running, sleeping) = (count(.running), count(.sleeping))
        if running == rows.count { return "All online" }
        if sleeping == rows.count { return "All asleep" }
        if running == 0 && sleeping == 0 { return "Nothing deployed" }
        // `5 online · 2 asleep`; services never deployed aren't counted.
        return [running > 0 ? "\(running) online" : nil, sleeping > 0 ? "\(sleeping) asleep" : nil]
            .compactMap(\.self).joined(separator: " · ")
    }

    /// The number a glance badges: failing services, or failing that, deploying ones.
    var attentionCount: Int {
        let failing = count(.failing)
        return failing > 0 ? failing : count(.deploying)
    }
}

/// `$9.02`
private func dollars(_ value: Double, fractionDigits: Int = 2) -> String {
    value.formatted(.currency(code: "USD").precision(.fractionLength(fractionDigits)))
}

// MARK: - Widget

struct RailwayWidgetView: View {
    let settings: RailwaySettings
    let layout: WidgetLayout
    @Environment(RailwayService.self) private var service

    var body: some View {
        let connection = service.connection(for: settings.account)
        TimelineView(.everyMinute) { context in
            content(connection, now: context.date)
        }
    }

    @ViewBuilder
    private func content(_ connection: RailwayConnection, now: Date) -> some View {
        if let snapshot = connection.snapshot {
            if let overview = RailwayOverview(snapshot: snapshot, settings: settings) {
                RailwayContent(
                    overview: overview, incidents: snapshot.incidents ?? [], commits: connection.commits,
                    details: connection.details, settings: settings, layout: layout, now: now,
                    footnote: connection.problem.map {
                        "\($0.title) · \(Formatting.shortAge(since: snapshot.fetchedAt, now: now)) ago"
                    })
            } else {
                RailwayMessage(
                    title: settings.workspaceName.map { "\($0) not found" } ?? "No workspace",
                    detail: RailwayFetchProblem.noWorkspace.advice, systemImage: "questionmark.folder", layout: layout)
            }
        } else if connection.needs == nil {
            // Fetched for no widget: a preview in the Widgets window before a Railway widget is added. Railway isn't
            // asked until then, so this shows what the widget looks like.
            RailwayContent(
                overview: RailwayOverview(snapshot: .sample, settings: RailwaySettings.sampled(settings))!,
                incidents: [], commits: Railway.Snapshot.sampleCommits, details: [:], settings: settings,
                layout: layout,
                now: Railway.Snapshot.sample.fetchedAt, footnote: nil)
        } else if let problem = connection.problem {
            RailwayMessage(
                title: problem.title, detail: problem.advice,
                systemImage: problem.needsSignIn ? "person.crop.circle.badge.questionmark" : "exclamationmark.triangle",
                layout: layout,
                action: problem.needsSignIn ? nil : ("Try Again", { service.refreshNow() }))
        } else {
            RailwayMessage(title: "Connecting to Railway…", detail: nil, systemImage: "hourglass", layout: layout)
        }
    }
}

extension RailwaySettings {
    /// These settings with the sample's workspace and environment, to preview them on the sample.
    fileprivate static func sampled(_ settings: RailwaySettings) -> RailwaySettings {
        var settings = settings
        settings.workspaceID = nil
        settings.projectID = nil
        settings.environmentName = nil
        return settings
    }
}

/// The blocks a Railway widget shows, for one overview.
private struct RailwayContent: View {
    let overview: RailwayOverview
    let incidents: [Railway.Incident]
    let commits: [String: Railway.Commit]
    let details: [RailwayServiceTarget: Railway.ServiceDetail]
    let settings: RailwaySettings
    let layout: WidgetLayout
    let now: Date
    /// Why the data is old, when it is.
    let footnote: String?

    /// The incidents block shows only while there's an incident.
    private var shownIncidents: [Railway.Incident] {
        incidents.filter { settings.blockOptions.incidents.showsMaintenance || !$0.isMaintenance }
    }

    private var blocks: [RailwayBlock] {
        settings.blocks.shownBlocks.filter { $0 != .incidents || !shownIncidents.isEmpty }
    }

    var body: some View {
        switch layout {
        case .regular, .compact:
            let blocks = blocks
            if blocks.isEmpty && settings.blocks.shownBlocks == [.incidents] {
                // Its only block shows only during an incident.
                Label("Railway reports no incidents", systemImage: "checkmark.circle")
                    .font(.system(size: layout == .regular ? 11 : 10))
                    .foregroundStyle(.secondary)
            } else if blocks.isEmpty {
                RailwayMessage(
                    title: "No blocks shown", detail: "Choose blocks in this widget's builder.",
                    systemImage: "square.stack.3d.up", layout: layout)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.element) { index, block in
                        if index > 0 {
                            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                                .padding(.vertical, layout == .regular ? 10 : 7)
                        }
                        view(for: block)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if let footnote {
                        Label(footnote, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.top, 8)
                    }
                }
                .animation(Motion.layout, value: blocks)
            }
        case .minimal:
            RailwayGlanceView(overview: overview, glance: settings.glance, isBar: false)
        case .bar:
            RailwayGlanceView(overview: overview, glance: settings.glance, isBar: true)
        }
    }

    @ViewBuilder
    private func view(for block: RailwayBlock) -> some View {
        let isCompact = layout == .compact
        switch block {
        case .summary:
            RailwaySummaryBlock(overview: overview, options: settings.blockOptions.summary, isCompact: isCompact)
        case .services:
            RailwayServicesBlock(
                overview: overview, commits: commits, options: settings.blockOptions.services, isCompact: isCompact,
                now: now)
        case .usage:
            RailwayUsageBlock(
                bill: overview.workspace.bill, options: settings.blockOptions.usage, isCompact: isCompact, now: now)
        case .incidents:
            RailwayIncidentsBlock(incidents: shownIncidents, isCompact: isCompact)
        case .service(let id):
            let options = settings.serviceOptions(id)
            let row = overview.row(projectID: options.projectID, serviceID: options.serviceID)
            RailwayServiceBlock(
                row: row, options: options, commit: row?.deployment.flatMap { commits[$0.id] },
                detail: row.flatMap { row in
                    details[
                        RailwayServiceTarget(
                            projectID: row.projectID, serviceID: row.serviceID,
                            environmentName: settings.environmentName)]
                },
                isCompact: isCompact, now: now)
        }
    }
}

// MARK: - Blocks

/// A dot in a health's color.
private struct HealthDot: View {
    let health: Railway.Health?
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(health?.color ?? .secondary)
            .frame(width: size, height: size)
            .opacity(health == .inactive ? 0.5 : 1)
            .animation(Motion.snappy, value: health)
    }
}

private struct RailwaySummaryBlock: View {
    let overview: RailwayOverview
    let options: RailwaySummaryOptions
    let isCompact: Bool

    var body: some View {
        let health = overview.health
        VStack(alignment: .leading, spacing: isCompact ? 2 : 3) {
            HStack(spacing: 6) {
                if isCompact { HealthDot(health: health, size: 6) }
                Text(overview.title)
                    .font(.system(size: isCompact ? 11.5 : 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !isCompact {
                    HStack(spacing: 5) {
                        HealthDot(health: health, size: 6)
                        Text(overview.healthTitle)
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(health == .running ? .secondary : health?.color ?? .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill((health?.color ?? .secondary).opacity(0.14)))
                    .contentTransition(.numericText())
                }
            }
            Text(subtitle)
                .font(.system(size: isCompact ? 9.5 : 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    /// `Acme · production · 7 services`
    private var subtitle: String {
        let showsWorkspace = options.showsWorkspace && overview.projects.count == 1
        let services = overview.rows.count == 1 ? "1 service" : "\(overview.rows.count) services"
        let parts = [
            showsWorkspace ? overview.workspace.name : nil,
            isCompact ? nil : overview.environmentName,
            isCompact ? overview.healthTitle : services,
        ]
        return parts.compactMap(\.self).joined(separator: " · ")
    }
}

private struct RailwayServicesBlock: View {
    let overview: RailwayOverview
    let commits: [String: Railway.Commit]
    let options: RailwayServicesOptions
    let isCompact: Bool
    let now: Date

    var body: some View {
        let all = overview.rows(ordered: options.order, showsSleeping: options.showsSleeping)
        let limit = isCompact ? min(options.maximumRows, 5) : options.maximumRows
        let rows = all.prefix(limit)
        let showsProject = overview.projects.count > 1
        VStack(alignment: .leading, spacing: isCompact ? 5 : 7) {
            if rows.isEmpty {
                Text(overview.rows.isEmpty ? "No services in this environment" : "All services asleep")
                    .font(.system(size: isCompact ? 10 : 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                RailwayServiceRowView(
                    row: row, commit: options.showsCommit ? row.deployment.flatMap { commits[$0.id] } : nil,
                    showsProject: showsProject, isCompact: isCompact, now: now)
            }
            if all.count > rows.count {
                Text("+\(all.count - rows.count) more")
                    .font(.system(size: isCompact ? 9.5 : 10))
                    .foregroundStyle(.secondary)
            }
        }
        .animation(Motion.gentle, value: rows.map(\.id))
    }
}

private struct RailwayServiceRowView: View {
    let row: RailwayServiceRow
    let commit: Railway.Commit?
    let showsProject: Bool
    let isCompact: Bool
    let now: Date
    @State private var isHovered = false

    private var isQuiet: Bool { row.health == .sleeping || row.health == .inactive }

    var body: some View {
        Button {
            if let url = row.dashboardURL { NSWorkspace.shared.open(url) }
        } label: {
            content.contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.primary.opacity(isHovered ? 0.08 : 0))
                .padding(.horizontal, -5)
                .padding(.vertical, isCompact ? -2 : -3)
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .contextMenu {
            if let url = row.dashboardURL {
                Button("Open in Railway", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
            }
            if let domain = row.deployment?.domain, let url = URL(string: "https://\(domain)") {
                Button("Open \(domain)", systemImage: "globe") { NSWorkspace.shared.open(url) }
            }
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
        .accessibilityHint("Opens the service in Railway")
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: isCompact ? 6 : 8) {
            HealthDot(health: row.health, size: isCompact ? 6 : 7)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3.5 }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(row.name)
                        .font(.system(size: isCompact ? 11 : 12, weight: .medium))
                        .foregroundStyle(isQuiet ? .secondary : .primary)
                        .lineLimit(1)
                    if showsProject && !isCompact {
                        Text(row.projectName).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    trailing
                }
                if !isCompact, let title = commit?.title {
                    Text(title)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// How long ago it deployed while all is well; what's going on otherwise.
    @ViewBuilder
    private var trailing: some View {
        let size: CGFloat = isCompact ? 9.5 : 10
        switch row.health {
        case .failing, .deploying:
            Text(row.statusTitle)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(row.health.color)
                .lineLimit(1)
        case .running, .sleeping, .inactive:
            if let createdAt = row.deployment?.createdAt {
                Text(Formatting.shortAge(since: createdAt, now: now))
                    .font(.system(size: size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var help: String {
        var parts = ["\(row.name): \(row.statusTitle)"]
        if let createdAt = row.deployment?.createdAt {
            parts.append("deployed \(createdAt.formatted(.relative(presentation: .named)))")
        }
        if let commit {
            parts.append(
                [commit.title, commit.branch.map { "on \($0)" }, commit.author.map { "by \($0)" }]
                    .compactMap(\.self).joined(separator: " "))
        }
        return parts.joined(separator: "\n")
    }
}

/// One service in detail.
private struct RailwayServiceBlock: View {
    /// `nil` before a service is chosen, or when the widget's projects and environment don't have it.
    let row: RailwayServiceRow?
    let options: RailwayServiceBlockOptions
    let commit: Railway.Commit?
    let detail: Railway.ServiceDetail?
    let isCompact: Bool
    let now: Date

    var body: some View {
        if let row {
            Group {
                if isCompact { compact(row) } else { regular(row) }
            }
            .contentShape(.rect)
            .onTapGesture { if let url = row.dashboardURL { NSWorkspace.shared.open(url) } }
            .contextMenu {
                if let url = row.dashboardURL {
                    Button("Open in Railway", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
                }
                if let url = websiteURL(row) {
                    Button("Open \(url.host() ?? "Website")", systemImage: "globe") { NSWorkspace.shared.open(url) }
                }
            }
            .help("Open \(row.name) in Railway")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        } else {
            Text(
                options.serviceID == nil
                    ? "Choose a service for this block in the builder."
                    : "\(options.serviceName ?? "The service") isn't in this widget's projects or environment."
            )
            .font(.system(size: isCompact ? 10 : 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func regular(_ row: RailwayServiceRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    HealthDot(health: row.health, size: 8)
                    Text(row.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(row.statusTitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(row.health == .running ? .secondary : row.health.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(row.health.color.opacity(0.14)))
                }
                Text(subtitle(row))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if options.showsCommit, let commit, let title = commit.title {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11.5)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let source = source(commit) {
                        Text(source).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if options.showsMetrics, let detail, !detail.cpu.isEmpty || !detail.memoryGB.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    RailwayMetric(title: "CPU", values: detail.cpu, value: detail.cpu.last.map(Self.cpu))
                    RailwayMetric(
                        title: "Memory", values: detail.memoryGB, value: detail.memoryGB.last.map(Self.memory))
                }
            }
            if (options.showsMetrics || options.showsHistory) && detail == nil {
                Text(loadingText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if options.showsHistory, let deploys = detail?.recentDeploys, !deploys.isEmpty {
                HStack(spacing: 5) {
                    Text("Recent deploys").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    // Oldest to newest, left to right.
                    ForEach(deploys.reversed()) { deploy in
                        Circle()
                            .fill(Self.historyColor(deploy.status))
                            .frame(width: 7, height: 7)
                            .help(
                                [deploy.status.title, deploy.createdAt?.formatted(.relative(presentation: .named))]
                                    .compactMap(\.self).joined(separator: ", "))
                    }
                }
            }
        }
    }

    private func compact(_ row: RailwayServiceRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                HealthDot(health: row.health, size: 6)
                Text(row.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 3)
                Text(row.health == .running ? age(row) ?? "" : row.statusTitle)
                    .font(.system(size: 9.5, weight: row.health == .running ? .regular : .medium))
                    .foregroundStyle(row.health == .running ? .secondary : row.health.color)
                    .monospacedDigit()
            }
            if options.showsMetrics, let detail, let cpu = detail.cpu.last, let memory = detail.memoryGB.last {
                Text("\(Self.cpu(cpu)) · \(Self.memory(memory))")
                    .font(.system(size: 9.5)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            } else if options.showsCommit, let title = commit?.title {
                Text(title).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// What's on its way, while a newly chosen service's details are fetched.
    private var loadingText: String {
        switch (options.showsMetrics, options.showsHistory) {
        case (true, true): "Loading CPU, memory and recent deploys…"
        case (true, false): "Loading CPU and memory…"
        default: "Loading recent deploys…"
        }
    }

    /// `api.up.railway.app · deployed 1d ago`
    private func subtitle(_ row: RailwayServiceRow) -> String {
        let parts = [row.deployment?.domain, age(row).map { "deployed \($0) ago" }]
        let subtitle = parts.compactMap(\.self).joined(separator: " · ")
        return subtitle.isEmpty ? row.projectName : subtitle
    }

    private func age(_ row: RailwayServiceRow) -> String? {
        row.deployment?.createdAt.map { Formatting.shortAge(since: $0, now: now) }
    }

    /// `main · 6821083 · ada`
    private func source(_ commit: Railway.Commit) -> String? {
        guard commit.message != nil else { return nil }
        let parts = [commit.branch, commit.hash.map { String($0.prefix(7)) }, commit.author]
        let source = parts.compactMap(\.self).joined(separator: " · ")
        return source.isEmpty ? nil : source
    }

    private func websiteURL(_ row: RailwayServiceRow) -> URL? {
        row.deployment?.domain.flatMap { URL(string: "https://\($0)") }
    }

    /// `0.02 vCPU`
    static func cpu(_ value: Double) -> String {
        value < 0.01 ? "<0.01 vCPU" : value.formatted(.number.precision(.fractionLength(2))) + " vCPU"
    }

    /// `225 MB`, `1.4 GB`
    static func memory(_ gigabytes: Double) -> String {
        gigabytes < 1
            ? "\(Int((gigabytes * 1000).rounded())) MB"
            : gigabytes.formatted(.number.precision(.fractionLength(1))) + " GB"
    }

    /// A replaced deploy ran fine, so it reads as a success.
    static func historyColor(_ status: Railway.DeploymentStatus) -> Color {
        switch status {
        case .success, .removed, .removing: .green
        case .crashed, .failed: .red
        case .skipped, .sleeping, .other: Color.secondary.opacity(0.5)
        case .queued, .waiting, .needsApproval, .initializing, .building, .deploying: .blue
        }
    }
}

/// A measurement over the last hour: its latest value and a sparkline.
private struct RailwayMetric: View {
    let title: String
    let values: [Double]
    let value: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value ?? "—").font(.system(size: 10.5, weight: .medium)).monospacedDigit()
            }
            // Sparkline scales to its largest value, so micro-units keep small values apart.
            Sparkline(values: values.map { Int64(($0 * 1_000_000).rounded()) }, height: 16)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RailwayUsageBlock: View {
    let bill: Railway.Bill?
    let options: RailwayUsageOptions
    let isCompact: Bool
    let now: Date

    var body: some View {
        if let bill {
            VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(dollars(bill.currentDollars))
                        .font(.system(size: isCompact ? 15 : 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: bill.currentDollars))
                    if !isCompact {
                        Text("so far").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if options.showsEstimate, let estimate = bill.estimatedDollars {
                        estimateLabel(estimate, bill: bill)
                    }
                }
                if options.showsLimit, let percent = bill.percentOfLimit, let limit = bill.limitDollars {
                    UsageBar(percent: min(percent, 100), height: isCompact ? 4 : 5)
                    if !isCompact {
                        HStack {
                            Text("Limit \(dollars(limit, fractionDigits: 0))")
                            Spacer()
                            resets(bill)
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                } else if !isCompact {
                    resets(bill).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("No bill: this sign-in can't see the workspace's billing.")
                .font(.system(size: isCompact ? 10 : 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func estimateLabel(_ estimate: Double, bill: Bill) -> some View {
        let overLimit = bill.limitDollars.map { estimate > $0 } ?? false
        if isCompact {
            Text("≈ \(dollars(estimate, fractionDigits: 0))")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(overLimit ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        } else {
            VStack(alignment: .trailing, spacing: 0) {
                Text("≈ \(dollars(estimate))")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(overLimit ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                Text(bill.periodEnd.map { "by \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? "this period")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    typealias Bill = Railway.Bill

    @ViewBuilder
    private func resets(_ bill: Bill) -> some View {
        if let end = bill.periodEnd {
            Text("Resets in \(Formatting.countdownLeadingUnit(to: end, now: now))")
        }
    }
}

private struct RailwayIncidentsBlock: View {
    let incidents: [Railway.Incident]
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 5 : 7) {
            ForEach(incidents.prefix(3)) { incident in
                Button {
                    NSWorkspace.shared.open(RailwayAPI.statusPageWebsite)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(
                            systemName: incident.isMaintenance
                                ? "wrench.and.screwdriver.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(incident.isMaintenance ? Color.blue : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(incident.title)
                                .font(.system(size: isCompact ? 10.5 : 11.5, weight: .medium))
                                .lineLimit(2)
                            if !isCompact, let detail = detail(incident) {
                                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: isCompact ? 10 : 11))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Open Railway's status page")
            }
        }
    }

    /// `Monitoring · US East`
    private func detail(_ incident: Railway.Incident) -> String? {
        let parts =
            [incident.status?.replacingOccurrences(of: "_", with: " ").capitalized]
            + incident.components
            .prefix(2).map(Optional.some)
        let detail = parts.compactMap(\.self).joined(separator: " · ")
        return detail.isEmpty ? nil : detail
    }
}

// MARK: - Glance

/// The one value the minimal and bar sizes show.
private struct RailwayGlanceView: View {
    let overview: RailwayOverview
    let glance: RailwayGlance
    let isBar: Bool

    var body: some View {
        Group {
            switch glance {
            case .health: health
            case .usage: usage
            }
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var health: some View {
        let state = overview.health
        let color = state == .running ? Color.green : state?.color ?? .secondary
        if isBar {
            HStack(spacing: 6) {
                WidgetIcon(metadata: .railway, size: 11).foregroundStyle(color)
                Text(overview.healthTitle).lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .contentTransition(.numericText())
        } else {
            let count = overview.attentionCount
            WidgetIcon(metadata: .railway, size: 18)
                .foregroundStyle(color)
                .frame(width: 28, height: 26)
                .overlay(alignment: .topTrailing) {
                    if count > 0, let state {
                        CountBadge(count: count, color: state.color)
                            .offset(x: 6, y: -5)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(Motion.snappy, value: count)
        }
    }

    @ViewBuilder
    private var usage: some View {
        if let bill = overview.workspace.bill {
            if isBar {
                HStack(spacing: 5) {
                    Image(systemName: "dollarsign.circle").foregroundStyle(.secondary)
                    Text(dollars(bill.currentDollars)).monospacedDigit()
                    if let estimate = bill.estimatedDollars {
                        Text("≈ \(dollars(estimate, fractionDigits: 0))").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .font(.system(size: 11, weight: .medium))
            } else {
                VStack(spacing: 4) {
                    Text(dollars(bill.currentDollars, fractionDigits: 0))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    if let percent = bill.percentOfLimit {
                        UsageBar(percent: min(percent, 100), height: 3).frame(width: 30)
                    }
                }
            }
        } else {
            Image(systemName: "dollarsign.circle").foregroundStyle(.secondary)
        }
    }

    private var help: String {
        var lines = ["\(overview.title): \(overview.healthTitle)"]
        if let bill = overview.workspace.bill {
            lines.append(
                "\(dollars(bill.currentDollars)) so far"
                    + (bill.estimatedDollars.map { ", about \(dollars($0)) by the end of the period" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Messages

private struct RailwayMessage: View {
    let title: String
    let detail: String?
    let systemImage: String
    let layout: WidgetLayout
    var action: (title: String, run: () -> Void)?

    var body: some View {
        let text = [title, detail].compactMap(\.self).joined(separator: ". ")
        if layout.isGlanceable {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .help(text)
                .accessibilityLabel(text)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(layout == .compact ? .system(size: 11) : .callout)
                if let detail, layout == .regular {
                    Text(detail).font(.caption).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                if let action, layout == .regular {
                    Button(action.title, action: action.run)
                        .controlSize(.small)
                        .padding(.top, 4)
                }
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .contain)
        }
    }
}

// MARK: - Sample

extension Railway.Snapshot {
    /// What the widget looks like before it's connected: an imaginary shop's services.
    static let sample: Railway.Snapshot = {
        let now = Date.now
        let environment = Railway.Environment(id: "production", name: "production")
        func service(
            _ name: String, _ status: Railway.DeploymentStatus, hoursAgo: Double, sleeps: Bool = false
        )
            -> Railway.Service
        {
            Railway.Service(
                id: name, name: name,
                instances: [
                    Railway.Instance(
                        environmentID: environment.id, sleeps: sleeps,
                        deployment: Railway.Deployment(
                            id: name, status: status, createdAt: now.addingTimeInterval(-hoursAgo * 3600)))
                ])
        }
        let project = Railway.Project(
            id: "storefront", name: "storefront", primaryEnvironmentID: environment.id, environments: [environment],
            services: [
                service("web", .success, hoursAgo: 2),
                service("api", .building, hoursAgo: 0.02),
                service("worker", .success, hoursAgo: 26),
                service("postgres", .success, hoursAgo: 24 * 12),
                service("redis", .success, hoursAgo: 24 * 30, sleeps: true),
            ])
        let bill = Railway.Bill(
            currentDollars: 12.4, estimatedDollars: 23.1, periodEnd: now.addingTimeInterval(9 * 86_400),
            hardLimitDollars: 50)
        return Railway.Snapshot(
            workspaces: [Railway.Workspace(id: "acme", name: "Acme", plan: "PRO", projects: [project], bill: bill)],
            incidents: [], fetchedAt: now)
    }()

    static let sampleCommits: [String: Railway.Commit] = [
        "web": Railway.Commit(message: "Add the new checkout flow", branch: "main"),
        "api": Railway.Commit(message: "Cache product search results", branch: "main"),
        "worker": Railway.Commit(message: "Retry failed webhooks with backoff", branch: "main"),
        "postgres": Railway.Commit(image: "ghcr.io/railwayapp-templates/postgres-ssl:17"),
        "redis": Railway.Commit(image: "redis:8"),
    ]
}
