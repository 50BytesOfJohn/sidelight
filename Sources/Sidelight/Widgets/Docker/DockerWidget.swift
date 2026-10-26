import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let docker = WidgetMetadata(
        title: "Docker",
        systemImage: "shippingbox",
        tint: .blue,
        summary: "Running containers and their health",
        details: "Containers in Docker Desktop, OrbStack or Colima, grouped by Compose project. Sidelight listens "
            + "for Docker's events instead of polling, never starts Docker, and reads CPU and memory only while "
            + "the details panel is open.",
        isBeta: true
    )
}

extension DockerSettings {
    var summary: String {
        let context = context.map { DockerContext(name: $0).displayName } ?? "Current context"
        return [Optional(context), showsStopped ? "stopped too" : nil, showsPorts ? nil : "no ports"].compactMap(\.self)
            .joined(separator: ", ")
    }
}

extension DockerProblem {
    var title: String {
        switch self {
        case .notRunning: "Docker isn't running"
        case .contextMissing(let name): "Context “\(name)” not found"
        case .permissionDenied: "Docker refused Sidelight"
        case .timedOut: "Docker didn't answer"
        case .failed: "Docker couldn't list containers"
        }
    }

    var detail: String {
        switch self {
        case .notRunning: "Containers show here once it starts."
        case .contextMissing: "Choose another in the widget's settings."
        case .permissionDenied: "Sidelight isn't allowed to use Docker's socket."
        case .timedOut: "It may still be starting."
        case .failed(let message): message
        }
    }
}

/// What a widget, or the details panel, shows for one context: its containers, or why there are none.
enum DockerDisplay {
    struct Message {
        var title: String
        var detail: String?
        var systemImage: String
        var action: (title: String, run: () -> Void)?
    }

    case message(Message)
    /// `note` says why the containers aren't live, and dims them.
    case containers(DockerSnapshot, note: String?)

    /// In a preview with nothing read for the context, the sample, as if connected.
    init(service: DockerService, choice: DockerContextChoice, isPreview: Bool, now: Date) {
        let connection = service.connection(choice)
        if isPreview, connection?.snapshot == nil {
            self = .containers(.sample(at: now), note: nil)
            return
        }
        guard !service.cliMissing else {
            self = .message(
                Message(
                    title: "Docker isn't installed", detail: "Install Docker Desktop, OrbStack or Colima.",
                    systemImage: "shippingbox"))
            return
        }
        let connecting = Message(title: "Connecting…", systemImage: "hourglass")
        guard let connection else {
            self = .message(connecting)
            return
        }
        switch connection.status {
        case .connected:
            self = connection.snapshot.map { .containers($0, note: nil) } ?? .message(connecting)
        case .notRunning:
            let name = service.displayName(for: choice)
            let app = service.runtimeApp(for: choice)
            self = .message(
                Message(
                    title: "Docker isn't running",
                    detail: "\(name == "Docker" ? "Docker" : name) is stopped. Containers show here once it starts.",
                    systemImage: "shippingbox",
                    action: app.map { app in ("Open \(app.name)", { service.openRuntime(for: choice) }) }))
        case .problem(.contextMissing(let name)):
            self = .message(
                Message(
                    title: DockerProblem.contextMissing(name).title, detail: DockerProblem.contextMissing(name).detail,
                    systemImage: "questionmark.circle"))
        case .problem(let problem):
            if let snapshot = connection.snapshot {
                self = .containers(snapshot, note: "Not updating · \(problem.title)")
            } else {
                self = .message(
                    Message(
                        title: problem.title, detail: problem.detail, systemImage: "exclamationmark.triangle",
                        action: ("Try Again", service.refreshNow)))
            }
        case .connecting:
            self =
                connection.snapshot.map { .containers($0, note: "Not updating · Connecting…") } ?? .message(connecting)
        }
    }
}

// MARK: - Widget

struct DockerWidgetView: View {
    let settings: DockerSettings
    let layout: WidgetLayout
    @Environment(DockerService.self) private var service
    @Environment(DetailsPresenter.self) private var details
    @Environment(\.widgetPlacement) private var placement
    @Environment(\.isWidgetPreview) private var isPreview

    var body: some View {
        WidgetClock { now in
            switch DockerDisplay(service: service, choice: settings.contextChoice, isPreview: isPreview, now: now) {
            case .message(let message):
                WidgetMessage(
                    title: message.title, detail: message.detail, systemImage: message.systemImage, layout: layout,
                    action: message.action.map {
                        WidgetMessage.Action(title: $0.title, runsOnGlanceClick: true, run: $0.run)
                    })
            case .containers(let snapshot, let note):
                content(snapshot, note: note)
                    .opacity(note == nil ? 1 : 0.6)
                    .animation(Motion.gentle, value: note)
            }
        }
    }

    @ViewBuilder
    private func content(_ snapshot: DockerSnapshot, note: String?) -> some View {
        switch layout {
        case .bar: bar(snapshot)
        case .minimal: minimal(snapshot)
        case .compact: compact(snapshot)
        case .regular: regular(snapshot, note: note)
        }
    }

    /// Opens every container in the details panel, in place of this panel. Only from a real panel: previews have no
    /// placement.
    private var open: (() -> Void)? {
        guard let placement, !isPreview else { return nil }
        let request = DetailsRequest.docker(context: settings.contextChoice)
        return { [details] in details.open(request, from: placement) }
    }

    /// The context's name, only when the widget is pinned to one: following the current context needs no label.
    private var contextName: String? {
        guard settings.context != nil else { return nil }
        return service.displayName(for: settings.contextChoice)
    }

    /// One line per issue, then the projects.
    private func tooltip(_ snapshot: DockerSnapshot) -> String {
        let summary = snapshot.summary
        let issues = summary.issues.map { "\($0.displayName): \(snapshot.condition(of: $0).title)" }
        let projects = snapshot.groups(scope: .active).map { "\($0.title) \($0.runningCount)/\($0.containers.count)" }
        return ([summary.headline] + issues + projects).joined(separator: "\n")
    }

    // MARK: Glance

    private func bar(_ snapshot: DockerSnapshot) -> some View {
        let summary = snapshot.summary
        return HStack(spacing: 6) {
            Image(systemName: "shippingbox")
                .foregroundStyle(summary.running == 0 ? Color.secondary : WidgetMetadata.docker.tint)
            Text(summary.running == 0 ? "None running" : "\(summary.running) running")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(summary.running)))
            if let issues = summary.issueText {
                Text(issues)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.orange))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .animation(Motion.snappy, value: summary)
        .opensIfPossible(open)
        .help(tooltip(snapshot))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tooltip(snapshot))
    }

    private func minimal(_ snapshot: DockerSnapshot) -> some View {
        let summary = snapshot.summary
        let hasIssues = !summary.issues.isEmpty
        return Image(systemName: "shippingbox")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(
                hasIssues ? Color.orange : summary.running > 0 ? WidgetMetadata.docker.tint : Color.secondary
            )
            .frame(width: 28, height: 26)
            .overlay(alignment: .topTrailing) {
                if summary.running > 0 {
                    CountBadge(count: summary.running, color: hasIssues ? .orange : .green)
                        .offset(x: 6, y: -5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(Motion.snappy, value: summary)
            .opensIfPossible(open)
            .help(glanceLabel(summary))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(glanceLabel(summary))
    }

    private func glanceLabel(_ summary: DockerSummary) -> String {
        ([summary.headline] + summary.issues.map(\.displayName)).joined(separator: "\n")
    }

    // MARK: Lists

    private func compact(_ snapshot: DockerSnapshot) -> some View {
        let summary = snapshot.summary
        let issues = Array(summary.issues.prefix(2))
        let groups = issues.isEmpty ? Array(snapshot.groups(scope: .active).prefix(2)) : []
        return VStack(alignment: .leading, spacing: 4) {
            DockerHeadline(summary: summary, contextName: contextName, size: 11)
            ForEach(issues) { container in
                HStack(spacing: 5) {
                    DockerConditionDot(condition: snapshot.condition(of: container), size: 6)
                    Text(container.displayName).lineLimit(1)
                    if let project = container.project {
                        Text(project).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(snapshot.condition(of: container).issueTitle ?? "").foregroundStyle(.orange)
                }
                .font(.system(size: 10.5))
            }
            ForEach(groups) { group in
                HStack(spacing: 5) {
                    DockerConditionDot(condition: group.worst, size: 6)
                    Text(group.title).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(group.runningCount)/\(group.containers.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 10.5))
            }
        }
        .animation(Motion.gentle, value: issues.map(\.id) + groups.map(\.id))
        .opensIfPossible(open)
        .help(tooltip(snapshot))
    }

    private func regular(_ snapshot: DockerSnapshot, note: String?) -> some View {
        let summary = snapshot.summary
        let groups = Array(snapshot.groups(scope: settings.showsStopped ? .all : .active).prefix(settings.rowCount))
        return VStack(alignment: .leading, spacing: 6) {
            DockerHeadline(summary: summary, contextName: contextName)
            if groups.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("No containers running").font(.system(size: 11.5))
                    if summary.stopped > 0 {
                        Text("\(summary.stopped) stopped").font(.system(size: 10.5))
                    }
                }
                .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: settings.showsPorts ? 6 : 2) {
                    ForEach(groups) { group in
                        DockerGroupRow(
                            group: group, showsPorts: settings.showsPorts, opensPorts: !isPreview, open: open
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(Motion.gentle, value: groups.map(\.id))
            }
            footer(total: snapshot.containers.count, note: note)
        }
    }

    private func footer(total: Int, note: String?) -> some View {
        HStack(spacing: 4) {
            Button {
                open?()
            } label: {
                HStack(spacing: 3) {
                    Text("View all \(total)")
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(open == nil)
            .hoverHighlight(isEnabled: open != nil, vertical: 1)
            .help(open == nil ? "Opens from the panel" : "See every container, searchable, in place of the panel")
            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

extension View {
    /// A click runs `action`, when there's one.
    @ViewBuilder
    fileprivate func opensIfPossible(_ action: (() -> Void)?) -> some View {
        if let action { opens(action) } else { self }
    }
}

// MARK: - Settings

struct DockerSettingsEditor: View {
    @Binding var settings: DockerSettings
    @Environment(DockerService.self) private var service

    var body: some View {
        Picker("Context", selection: $settings.context) {
            Text("Current (\(service.displayName(for: .current)))").tag(String?.none)
            if !choices.isEmpty { Divider() }
            ForEach(choices, id: \.name) { choice in
                Text(choice.label).tag(Optional(choice.name))
            }
        }
        Toggle("Show stopped containers", isOn: $settings.showsStopped)
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Show ports", isOn: $settings.showsPorts)
            SettingsCaption("Published ports under each project. Click one to open it in your browser.")
        }
        VStack(alignment: .leading, spacing: 2) {
            Stepper(
                "Projects listed: \(settings.rowCount)", value: $settings.rowCount, in: DockerSettings.rowCountRange)
            SettingsCaption("In the regular layout. Compact shows issues only.")
        }
        StatusRow(color: statusColor, text: statusText) {
            Spacer(minLength: 4)
            InfoButton(
                "Sidelight runs the docker command you installed. It listens for Docker's events instead of "
                    + "polling, so it costs nothing while nothing changes, and it never starts Docker. CPU and "
                    + "memory are read only while the details panel is open.")
        }
        if case .problem = connection?.status {
            Button("Try Again") { service.refreshNow() }
        }
    }

    private var connection: DockerConnection? { service.connection(settings.contextChoice) }

    /// Every context the CLI knows, and the chosen one even when it's gone.
    private var choices: [(name: String, label: String)] {
        var choices = service.contexts.map { context in
            (
                name: context.name,
                label: context.displayName == context.name ? context.name : "\(context.displayName) (\(context.name))"
            )
        }
        if let name = settings.context, !choices.contains(where: { $0.name == name }) {
            choices.append((name: name, label: "\(name) (not found)"))
        }
        return choices
    }

    private var statusText: String {
        guard !service.cliMissing else { return "Docker isn't installed" }
        guard let connection else { return "Connects once the widget shows" }
        switch connection.status {
        case .connecting: return "Connecting…"
        case .connected: return "Connected · \(connection.snapshot?.summary.headline ?? "")"
        case .notRunning: return "Docker isn't running"
        case .problem(let problem): return problem.title
        }
    }

    private var statusColor: Color {
        guard !service.cliMissing, let connection else { return .secondary }
        switch connection.status {
        case .connected: return .green
        case .connecting: return .blue
        case .notRunning: return .secondary
        case .problem: return .orange
        }
    }
}
