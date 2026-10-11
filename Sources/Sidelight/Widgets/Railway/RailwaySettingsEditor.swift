import SidelightCore
import SwiftUI

extension RailwayBlock: DescribedBlock {
    var title: String {
        switch self {
        case .summary: "Summary"
        case .services: "Services"
        case .usage: "Usage"
        case .incidents: "Railway Status"
        case .service: "Service"
        }
    }

    var systemImage: String {
        switch self {
        case .summary: "text.below.photo"
        case .services: "square.stack.3d.up"
        case .usage: "dollarsign.circle"
        case .incidents: "exclamationmark.triangle"
        case .service: "cube"
        }
    }

    var blurb: String {
        switch self {
        case .summary: "The project or workspace, and how its services are doing."
        case .services: "Each service with its latest deploy. Click one to open it."
        case .usage: "The bill so far, where it's heading, and your usage limit."
        case .incidents: "Railway's incidents and maintenance, only while there's one."
        case .service: "One service in detail: its deploy, commit, CPU, memory and recent deploys."
        }
    }
}

extension RailwaySettings: BlockBuiltWidget {
    static let presets = [
        BlockPreset<RailwayBlock>(
            id: "overview", title: "Overview", systemImage: "square.grid.2x2",
            summary: "Summary, services, bill and Railway's incidents",
            blocks: [.summary, .services, .usage, .incidents]),
        BlockPreset(
            id: "services", title: "Services", systemImage: "square.stack.3d.up",
            summary: "Just the services and their deploys", blocks: [.services, .incidents]),
        BlockPreset(
            id: "costs", title: "Costs", systemImage: "dollarsign.circle",
            summary: "The bill against your usage limit", blocks: [.usage, .summary]),
    ]

    static func options(for block: RailwayBlock, settings: Binding<RailwaySettings>) -> some View {
        RailwayBlockOptionsEditor(block: block, settings: settings)
    }

    static func widgetOptions(settings: Binding<RailwaySettings>) -> some View {
        RailwayWidgetOptions(settings: settings)
    }

    static let addableBlocks = [
        AddableBlock(
            id: "service", title: "Service", systemImage: "cube",
            blurb: "One service in detail. Add one for each service to watch.")
    ]

    mutating func addBlock(_ id: AddableBlock.ID) -> RailwayBlock? {
        id == "service" ? addServiceBlock() : nil
    }

    func title(of block: RailwayBlock) -> String {
        guard case .service(let id) = block else { return block.title }
        return serviceOptions(id).serviceName ?? "Service"
    }
}

extension RailwayAccountChoice {
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .cli: "Railway CLI"
        case .token: "API token"
        }
    }
}

extension RailwayServiceOrder {
    var title: String {
        switch self {
        case .attention: "Needs attention first"
        case .name: "Name"
        case .recent: "Latest deploy first"
        }
    }
}

extension RailwayGlance {
    var title: String {
        switch self {
        case .health: "Health"
        case .usage: "Bill"
        }
    }
}

/// The Widgets window's settings for a Railway widget: a ready-made layout, and the options for the whole widget.
/// Blocks are arranged in the builder.
struct RailwaySettingsEditor: View {
    @Binding var settings: RailwaySettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Layout", selection: preset) {
                ForEach(RailwaySettings.presets) { Text($0.title).tag(Optional($0.id)) }
                if preset.wrappedValue == nil { Text("Custom").tag(String?.none) }
            }
            caption("Open the builder to arrange the blocks and set each one's options.")
        }
        Divider()
        RailwayWidgetOptions(settings: $settings)
    }

    private var preset: Binding<String?> {
        Binding {
            RailwaySettings.presets.first { $0.matches(settings.blocks) }?.id
        } set: { id in
            guard let preset = RailwaySettings.presets.first(where: { $0.id == id }) else { return }
            settings.blocks.showOnly(preset.blocks)
        }
    }
}

/// Whose Railway account, which part of it, how often to ask, and what the smallest sizes show.
struct RailwayWidgetOptions: View {
    @Binding var settings: RailwaySettings
    @Environment(RailwayService.self) private var service

    var body: some View {
        let connection = service.connection(for: settings.account)
        VStack(alignment: .leading, spacing: 8) {
            Picker("Sign in with", selection: $settings.account) {
                ForEach(RailwayAccountChoice.allCases) { Text($0.title).tag($0) }
            }
            signInStatus(connection)
            if service.resolved(settings.account) == .token || service.hasToken {
                RailwayTokenField()
            }
            caption(accountCaption)
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Picker("Workspace", selection: workspace(connection)) {
                Text("First workspace").tag(String?.none)
                ForEach(workspaces(connection), id: \.id) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("Project", selection: project(connection)) {
                Text("All projects").tag(String?.none)
                ForEach(projects(connection), id: \.id) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("Environment", selection: $settings.environmentName) {
                Text("Primary").tag(String?.none)
                ForEach(environmentNames(connection), id: \.self) { Text($0).tag(Optional($0)) }
            }
            caption("The primary environment is usually production.")
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Picker("Refresh", selection: $settings.refreshMinutes) {
                Text("Automatic").tag(Int?.none)
                ForEach(RailwaySettings.refreshMinuteChoices, id: \.self) { minutes in
                    Text(minutes == 1 ? "Every minute" : "Every \(minutes) minutes").tag(Optional(minutes))
                }
            }
            caption(refreshCaption(connection))
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Picker("Minimal and bar show", selection: $settings.glance) {
                ForEach(RailwayGlance.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    @ViewBuilder
    private func signInStatus(_ connection: RailwayConnection) -> some View {
        let (text, color) = signInText(connection)
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.callout)
            Spacer(minLength: 0)
            if connection.problem != nil || connection.snapshot != nil {
                Button("Refresh") { service.refreshNow() }
                    .controlSize(.small)
                    .disabled(connection.isFetching)
            }
        }
    }

    private func signInText(_ connection: RailwayConnection) -> (String, Color) {
        if let problem = connection.problem { return (problem.title, problem.needsSignIn ? .orange : .yellow) }
        if connection.snapshot != nil {
            let who = connection.snapshot?.userName.map { " as \($0)" } ?? ""
            let via = connection.source == .cli ? "Railway CLI" : "API token"
            return ("Signed in\(who) with the \(via)", .green)
        }
        switch service.resolved(settings.account) {
        case .cli:
            if service.cliExecutable == nil && !service.cliIsSignedIn { return ("Railway CLI not found", .secondary) }
            return service.cliIsSignedIn ? ("Railway CLI signed in", .blue) : ("Railway CLI not signed in", .orange)
        case .token:
            return service.hasToken ? ("Token saved", .blue) : ("No token saved", .orange)
        }
    }

    private var accountCaption: String {
        switch settings.account {
        case .automatic:
            "Uses the Railway CLI's sign-in (railway login) when it has one, otherwise a token saved here. The CLI renews "
                + "its sign-in itself; Sidelight only reads it."
        case .cli:
            "Uses the Railway CLI's sign-in from railway login. Sidelight only reads it, and runs the CLI to renew it."
        case .token:
            "An account token from railway.com/account/tokens, kept in your keychain. It sees what your account sees."
        }
    }

    private func refreshCaption(_ connection: RailwayConnection) -> String {
        let limit = connection.rateLimit?.hourlyLimit.map { Int($0) }
        let share = limit.map {
            " Railway allows this account \($0.formatted()) requests an hour, shared with the CLI."
        }
        if settings.refreshMinutes == nil {
            return "Every 2 minutes, quicker while something deploys, and never more than a small share of the "
                + "rate limit. The bill refreshes every 15 minutes." + (share ?? "")
        }
        return "The bill refreshes every 15 minutes, or at this pace if slower." + (share ?? "")
    }

    // MARK: Scope

    private func workspaces(_ connection: RailwayConnection) -> [RailwayAPI.Account.Workspace] {
        var workspaces = connection.account?.workspaces ?? []
        if let id = settings.workspaceID, !workspaces.contains(where: { $0.id == id }) {
            workspaces.append(.init(id: id, name: settings.workspaceName ?? "Chosen workspace"))
        }
        return workspaces
    }

    private func projects(_ connection: RailwayConnection) -> [(id: String, name: String)] {
        var projects = (connection.snapshot?.workspace(id: settings.workspaceID)?.projects ?? []).map {
            (id: $0.id, name: $0.name)
        }
        if let id = settings.projectID, !projects.contains(where: { $0.id == id }) {
            projects.append((id: id, name: settings.projectName ?? "Chosen project"))
        }
        return projects
    }

    private func environmentNames(_ connection: RailwayConnection) -> [String] {
        let projects = (connection.snapshot?.workspace(id: settings.workspaceID)?.projects ?? [])
            .filter { settings.projectID == nil || $0.id == settings.projectID }
        var names = Set(projects.flatMap { $0.environments.filter { !$0.isEphemeral }.map(\.name) })
        if let name = settings.environmentName { names.insert(name) }
        return names.sorted()
    }

    private func workspace(_ connection: RailwayConnection) -> Binding<String?> {
        Binding {
            settings.workspaceID
        } set: { id in
            settings.workspaceID = id
            settings.workspaceName = id.flatMap { id in workspaces(connection).first { $0.id == id }?.name }
            settings.projectID = nil
            settings.projectName = nil
        }
    }

    private func project(_ connection: RailwayConnection) -> Binding<String?> {
        Binding {
            settings.projectID
        } set: { id in
            settings.projectID = id
            settings.projectName = id.flatMap { id in projects(connection).first { $0.id == id }?.name }
        }
    }
}

/// Saving or removing the API token.
private struct RailwayTokenField: View {
    @Environment(RailwayService.self) private var service
    @State private var draft = ""
    @State private var isSaving = false
    @State private var problem: RailwayFetchProblem?

    var body: some View {
        if service.hasToken {
            HStack {
                Label("Token saved in your keychain", systemImage: "key.fill").font(.callout)
                Spacer()
                Button("Remove", role: .destructive) { service.removeToken() }.controlSize(.small)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                SecureField("Account token", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                HStack {
                    Button(isSaving ? "Checking…" : "Save Token", action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                    Spacer()
                    Link("Create a token", destination: URL(string: "https://railway.com/account/tokens")!)
                        .font(.callout)
                }
                .controlSize(.small)
                if let problem {
                    Text("\(problem.title). \(problem.advice)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            problem = await service.saveToken(draft)
            isSaving = false
            if problem == nil { draft = "" }
        }
    }
}

/// One Railway block's options.
private struct RailwayBlockOptionsEditor: View {
    let block: RailwayBlock
    @Binding var settings: RailwaySettings

    var body: some View {
        switch block {
        case .summary:
            Toggle("Show the workspace", isOn: $settings.blockOptions.summary.showsWorkspace)
            caption("Next to the project's name, when the widget shows one project.")
        case .services:
            Picker("Order", selection: $settings.blockOptions.services.order) {
                ForEach(RailwayServiceOrder.allCases) { Text($0.title).tag($0) }
            }
            Stepper(value: $settings.blockOptions.services.maximumRows, in: RailwayServicesOptions.rowCountRange) {
                Text("Up to \(settings.blockOptions.services.maximumRows) services")
            }
            Toggle("Show asleep services", isOn: $settings.blockOptions.services.showsSleeping)
            Toggle("Show commit messages", isOn: $settings.blockOptions.services.showsCommit)
            caption(
                "The latest deploy's commit, or its image. Asked for once per new deploy, in the regular size only.")
        case .usage:
            Toggle("Show the estimate", isOn: $settings.blockOptions.usage.showsEstimate)
            caption("Where the bill is heading by the end of the billing period, at the current rate.")
            Toggle("Show the usage limit", isOn: $settings.blockOptions.usage.showsLimit)
            caption("The bill against the hard limit, or the soft one, set in your workspace's usage settings.")
        case .incidents:
            Toggle("Include planned maintenance", isOn: $settings.blockOptions.incidents.showsMaintenance)
            caption("From status.railway.com. The block shows only while Railway reports something.")
        case .service(let id):
            RailwayServiceBlockEditor(id: id, settings: $settings)
        }
    }
}

/// Which service a Service block shows, and what of it.
private struct RailwayServiceBlockEditor: View {
    let id: UUID
    @Binding var settings: RailwaySettings
    @Environment(RailwayService.self) private var service

    var body: some View {
        Picker("Service", selection: chosen) {
            Text("Choose…").tag(String?.none)
            ForEach(choices, id: \.key) { choice in
                Text(choice.title).tag(Optional(choice.key))
            }
        }
        caption("From the widget's projects, in its environment.")
        Toggle("Show the commit", isOn: option(\.showsCommit))
        Toggle("Show CPU and memory", isOn: option(\.showsMetrics))
        Toggle("Show recent deploys", isOn: option(\.showsHistory))
        caption("CPU, memory and deploys ride along with each refresh, in the same request.")
    }

    private struct Choice {
        var key: String
        var title: String
        var projectID: String
        var serviceID: String
        var name: String
    }

    /// The widget's services, and the chosen one even when Railway can't be asked right now.
    private var choices: [Choice] {
        let connection = service.connection(for: settings.account)
        let rows = connection.snapshot.flatMap { RailwayOverview(snapshot: $0, settings: settings) }?.rows ?? []
        let showsProject = Set(rows.map(\.projectID)).count > 1
        var choices = rows.sorted { ($0.projectName, $0.name) < ($1.projectName, $1.name) }.map { row in
            Choice(
                key: "\(row.projectID)/\(row.serviceID)",
                title: showsProject ? "\(row.name) (\(row.projectName))" : row.name,
                projectID: row.projectID, serviceID: row.serviceID, name: row.name)
        }
        let options = settings.serviceOptions(id)
        if let projectID = options.projectID, let serviceID = options.serviceID,
            !choices.contains(where: { $0.projectID == projectID && $0.serviceID == serviceID })
        {
            let name = options.serviceName ?? "Chosen service"
            choices.append(
                Choice(
                    key: "\(projectID)/\(serviceID)", title: name, projectID: projectID, serviceID: serviceID,
                    name: name))
        }
        return choices
    }

    private var chosen: Binding<String?> {
        Binding {
            let options = settings.serviceOptions(id)
            guard let projectID = options.projectID, let serviceID = options.serviceID else { return nil }
            return "\(projectID)/\(serviceID)"
        } set: { key in
            var options = settings.serviceOptions(id)
            let choice = choices.first { $0.key == key }
            options.projectID = choice?.projectID
            options.serviceID = choice?.serviceID
            options.serviceName = choice?.name
            settings.setServiceOptions(options, for: id)
        }
    }

    private func option(_ keyPath: WritableKeyPath<RailwayServiceBlockOptions, Bool>) -> Binding<Bool> {
        Binding {
            settings.serviceOptions(id)[keyPath: keyPath]
        } set: { value in
            var options = settings.serviceOptions(id)
            options[keyPath: keyPath] = value
            settings.setServiceOptions(options, for: id)
        }
    }
}

private func caption(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}
