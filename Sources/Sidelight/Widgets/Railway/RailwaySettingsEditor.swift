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
        BlockPresetPicker(settings: $settings)
        RailwayWidgetOptions(settings: $settings)
    }
}

/// Whose Railway account, which part of it, how often to ask, and what the smallest sizes show.
struct RailwayWidgetOptions: View {
    @Binding var settings: RailwaySettings
    @Environment(RailwayService.self) private var service
    @Environment(AccountStore.self) private var accounts

    var body: some View {
        let connection = connection
        AccountPicker(provider: .railway, selection: $settings.account)
        signInStatus(connection)
        Picker("Workspace", selection: workspace(connection)) {
            Text("First workspace").tag(String?.none)
            ForEach(workspaces(connection), id: \.id) { Text($0.name).tag(Optional($0.id)) }
        }
        Picker("Project", selection: project(connection)) {
            Text("All projects").tag(String?.none)
            ForEach(projects(connection), id: \.id) { Text($0.name).tag(Optional($0.id)) }
        }
        Picker(selection: $settings.environmentName) {
            Text("Primary").tag(String?.none)
            ForEach(environmentNames(connection), id: \.self) { Text($0).tag(Optional($0)) }
        } label: {
            InfoLabel("Environment", info: "The primary environment is usually production.")
        }
        Picker(selection: $settings.refreshMinutes) {
            Text("Automatic").tag(Int?.none)
            ForEach(RailwaySettings.refreshMinuteChoices, id: \.self) { minutes in
                Text(minutes == 1 ? "Every minute" : "Every \(minutes) minutes").tag(Optional(minutes))
            }
        } label: {
            InfoLabel("Refresh", info: refreshCaption(connection))
        }
        Picker("Minimal and bar show", selection: $settings.glance) {
            ForEach(RailwayGlance.allCases) { Text($0.title).tag($0) }
        }
    }

    /// The account the widget uses, and Railway as it sees it once the widget has fetched with it.
    private var resolution: AccountResolution { accounts.resolve(settings.account, at: .railway) }

    private var connection: RailwayConnection? {
        resolution.accountID.flatMap(service.connection)
    }

    @ViewBuilder
    private func signInStatus(_ connection: RailwayConnection?) -> some View {
        if let (text, color) = signInText(connection) {
            StatusRow(color: color, text: text) {
                Spacer(minLength: 0)
                if let connection, connection.problem != nil || connection.snapshot != nil {
                    Button("Refresh") { service.refreshNow() }
                        .controlSize(.small)
                        .disabled(connection.isFetching)
                }
            }
        }
    }

    private func signInText(_ connection: RailwayConnection?) -> (String, Color)? {
        guard let id = resolution.accountID else { return nil }
        if let problem = connection?.problem { return (problem.title, problem.needsSignIn ? .orange : .yellow) }
        if let snapshot = connection?.snapshot {
            let who = snapshot.userName.map { "Signed in as \($0)" } ?? "Signed in"
            return (who, .green)
        }
        guard id == .railwayCLI else { return nil }
        if service.cliExecutable == nil && !service.cliIsSignedIn { return ("Railway CLI not found", .secondary) }
        return service.cliIsSignedIn ? ("Railway CLI signed in", .blue) : ("Railway CLI not signed in", .orange)
    }

    private func refreshCaption(_ connection: RailwayConnection?) -> String {
        let limit = connection?.rateLimit?.hourlyLimit.map { Int($0) }
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

    private func workspaces(_ connection: RailwayConnection?) -> [RailwayAPI.Account.Workspace] {
        var workspaces = connection?.account?.workspaces ?? []
        if let id = settings.workspaceID, !workspaces.contains(where: { $0.id == id }) {
            workspaces.append(.init(id: id, name: settings.workspaceName ?? "Chosen workspace"))
        }
        return workspaces
    }

    private func projects(_ connection: RailwayConnection?) -> [(id: String, name: String)] {
        var projects = (connection?.snapshot?.workspace(id: settings.workspaceID)?.projects ?? []).map {
            (id: $0.id, name: $0.name)
        }
        if let id = settings.projectID, !projects.contains(where: { $0.id == id }) {
            projects.append((id: id, name: settings.projectName ?? "Chosen project"))
        }
        return projects
    }

    private func environmentNames(_ connection: RailwayConnection?) -> [String] {
        let projects = (connection?.snapshot?.workspace(id: settings.workspaceID)?.projects ?? [])
            .filter { settings.projectID == nil || $0.id == settings.projectID }
        var names = Set(projects.flatMap { $0.environments.filter { !$0.isEphemeral }.map(\.name) })
        if let name = settings.environmentName { names.insert(name) }
        return names.sorted()
    }

    private func workspace(_ connection: RailwayConnection?) -> Binding<String?> {
        Binding {
            settings.workspaceID
        } set: { id in
            settings.workspaceID = id
            settings.workspaceName = id.flatMap { id in workspaces(connection).first { $0.id == id }?.name }
            settings.projectID = nil
            settings.projectName = nil
        }
    }

    private func project(_ connection: RailwayConnection?) -> Binding<String?> {
        Binding {
            settings.projectID
        } set: { id in
            settings.projectID = id
            settings.projectName = id.flatMap { id in projects(connection).first { $0.id == id }?.name }
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
            Toggle(isOn: $settings.blockOptions.summary.showsWorkspace) {
                InfoLabel("Show the workspace", info: "Next to the project's name, when the widget shows one project.")
            }
        case .services:
            Picker("Order", selection: $settings.blockOptions.services.order) {
                ForEach(RailwayServiceOrder.allCases) { Text($0.title).tag($0) }
            }
            Stepper(value: $settings.blockOptions.services.maximumRows, in: RailwayServicesOptions.rowCountRange) {
                Text("Up to \(settings.blockOptions.services.maximumRows) services")
            }
            Toggle("Show asleep services", isOn: $settings.blockOptions.services.showsSleeping)
            Toggle(isOn: $settings.blockOptions.services.showsCommit) {
                InfoLabel(
                    "Show commit messages",
                    info: "The latest deploy's commit, or its image. Fetched once per new deploy, in regular cards "
                        + "only.")
            }
        case .usage:
            Toggle(isOn: $settings.blockOptions.usage.showsEstimate) {
                InfoLabel(
                    "Show the estimate", info: "The bill at the end of the billing period, at the current rate.")
            }
            Toggle(isOn: $settings.blockOptions.usage.showsLimit) {
                InfoLabel(
                    "Show the usage limit",
                    info: "The bill against the hard limit, or the soft one, from your workspace's usage settings.")
            }
        case .incidents:
            Toggle(isOn: $settings.blockOptions.incidents.showsMaintenance) {
                InfoLabel(
                    "Include planned maintenance",
                    info: "From status.railway.com. The block shows only while Railway reports something.")
            }
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
    @Environment(AccountStore.self) private var accounts

    var body: some View {
        Picker(selection: chosen) {
            Text("Choose…").tag(String?.none)
            ForEach(choices, id: \.key) { choice in
                Text(choice.title).tag(Optional(choice.key))
            }
        } label: {
            InfoLabel("Service", info: "From the widget's projects, in its environment.")
        }
        Toggle("Show the commit", isOn: option(\.showsCommit))
        Toggle(isOn: option(\.showsMetrics)) {
            InfoLabel("Show CPU and memory", info: "Fetched with each refresh, in the same request. No extra cost.")
        }
        Toggle(isOn: option(\.showsHistory)) {
            InfoLabel("Show recent deploys", info: "Fetched with each refresh, in the same request. No extra cost.")
        }
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
        let connection = accounts.resolve(settings.account, at: .railway).accountID.flatMap(service.connection)
        let rows = connection?.snapshot.flatMap { RailwayOverview(snapshot: $0, settings: settings) }?.rows ?? []
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
