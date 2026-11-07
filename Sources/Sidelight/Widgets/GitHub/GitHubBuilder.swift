import SidelightCore
import SwiftUI

extension GitHubBlock: DescribedBlock {
    var title: String {
        switch self {
        case .summary: "At a Glance"
        case .reviewRequests: "Review Requests"
        case .pullRequests: "Your Pull Requests"
        case .issues: "Issues"
        case .notifications: "Inbox"
        case .contributions: "Contributions"
        case .status: "GitHub Status"
        case .repository: "Repository"
        }
    }

    var systemImage: String {
        switch self {
        case .summary: "number"
        case .reviewRequests: "eye"
        case .pullRequests: "arrow.triangle.pull"
        case .issues: "smallcircle.filled.circle"
        case .notifications: "bell"
        case .contributions: "square.grid.3x3.fill"
        case .status: "exclamationmark.triangle"
        case .repository: "book.closed"
        }
    }

    var blurb: String {
        switch self {
        case .summary: "One line of counts: reviews waiting, your pull requests, issues and unread notifications."
        case .reviewRequests: "Pull requests waiting for your review, most recently updated first."
        case .pullRequests: "Your open pull requests, with their checks, reviews and conflicts."
        case .issues: "Open issues assigned to you, opened by you, or mentioning you."
        case .notifications: "Unread notifications from your GitHub inbox."
        case .contributions: "Your contribution calendar and streak."
        case .status: "GitHub's incidents and maintenance. Shows only while there is one."
        case .repository: "One repository: its default branch's checks, latest release, and open pull requests."
        }
    }
}

extension GitHubPreset {
    var title: String {
        switch self {
        case .focus: "Focus"
        case .glance: "At a glance"
        case .triage: "Triage"
        case .activity: "Activity"
        case .everything: "Everything"
        }
    }
}

extension GitHubSettings: BlockBuiltWidget {
    static let presets = GitHubPreset.allCases.map { preset in
        BlockPreset<GitHubBlock>(id: preset.rawValue, title: preset.title, blocks: preset.blocks)
    }

    static func options(for block: GitHubBlock, settings: Binding<GitHubSettings>) -> some View {
        GitHubBlockOptionsEditor(block: block, settings: settings)
    }

    static func widgetOptions(settings: Binding<GitHubSettings>) -> some View {
        GitHubWidgetOptions(settings: settings)
    }

    static let addableBlocks = [AddableBlock(id: "repository", title: "Repository", systemImage: "book.closed")]

    mutating func addBlock(_ id: AddableBlock.ID) -> GitHubBlock? {
        id == "repository" ? addRepositoryBlock() : nil
    }

    func title(of block: GitHubBlock) -> String {
        guard case .repository(let id) = block else { return block.title }
        return repositoryOptions(id).repository ?? "Repository"
    }

    func variants(of block: GitHubBlock) -> [BlockVariant] {
        guard listOptions(of: block) != nil else { return [] }
        return [
            BlockVariant(id: GitHubRowStyle.singleLine.rawValue, title: "Single line", summary: "One line per row."),
            BlockVariant(
                id: GitHubRowStyle.detailed.rawValue, title: "Detailed",
                summary: "Two lines per row: the repository, author, comments and size under the title."),
        ]
    }

    func variantID(of block: GitHubBlock) -> String? {
        listOptions(of: block)?.rowStyle.rawValue
    }

    mutating func setVariant(_ id: String, of block: GitHubBlock) {
        guard let style = GitHubRowStyle(rawValue: id) else { return }
        switch block {
        case .reviewRequests: blockOptions.reviewRequests.list.rowStyle = style
        case .pullRequests: blockOptions.pullRequests.list.rowStyle = style
        case .issues: blockOptions.issues.list.rowStyle = style
        case .notifications: blockOptions.notifications.list.rowStyle = style
        case .summary, .contributions, .status, .repository: break
        }
    }

    /// The options of a block that lists rows; `nil` for any other.
    func listOptions(of block: GitHubBlock) -> GitHubListOptions? {
        switch block {
        case .reviewRequests: blockOptions.reviewRequests.list
        case .pullRequests: blockOptions.pullRequests.list
        case .issues: blockOptions.issues.list
        case .notifications: blockOptions.notifications.list
        case .summary, .contributions, .status, .repository: nil
        }
    }
}

extension GitHubGlance {
    var title: String {
        switch self {
        case .attention: "What needs you"
        case .reviews: "Review requests"
        case .pullRequests: "Your pull requests"
        case .notifications: "Unread notifications"
        }
    }
}

extension GitHubIssueScope {
    var title: String {
        switch self {
        case .assigned: "Assigned to you"
        case .created: "Opened by you"
        case .mentioned: "Mentioning you"
        }
    }
}

/// The Widgets window's settings for a GitHub widget: a ready-made layout, and the options for the whole widget.
/// Blocks are arranged in the builder.
struct GitHubSettingsEditor: View {
    @Binding var settings: GitHubSettings

    var body: some View {
        BlockPresetPicker(settings: $settings)
        GitHubWidgetOptions(settings: $settings)
    }
}

/// Whose GitHub, which repositories, how often to ask, and what the smallest sizes show.
private struct GitHubWidgetOptions: View {
    @Binding var settings: GitHubSettings
    @Environment(GitHubService.self) private var service
    @Environment(AccountStore.self) private var accounts

    var body: some View {
        AccountPicker(provider: .gitHub, selection: $settings.account)
        if let (text, color) = statusText {
            StatusRow(color: color, text: text) {
                Spacer(minLength: 0)
                if let connection, connection.snapshot.value != nil || connection.snapshot.problem != nil {
                    Button("Refresh") { service.refreshNow() }
                        .controlSize(.small)
                        .disabled(connection.snapshot.isFetching)
                }
            }
        }
        GitHubRepositoryFilterEditor(
            entries: $settings.repositories, suggestions: GitHubSuggestions.repositories(in: connection?.snapshot.value)
        )
        ExpandableRow(title: "Advanced") {
            Picker(selection: $settings.refresh) {
                Text("Manually").tag(RefreshCadence.manual)
                ForEach(refreshChoices, id: \.self) { minutes in
                    Text(minutes == 1 ? "Every minute" : "Every \(minutes) minutes").tag(
                        RefreshCadence.minutes(minutes))
                }
            } label: {
                InfoLabel("Refresh", info: refreshInfo)
            }
            Picker("Minimal and bar show", selection: $settings.glance) {
                ForEach(GitHubGlance.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    private var resolution: AccountResolution { accounts.resolve(settings.account, at: .gitHub) }

    private var connection: GitHubConnection? { resolution.accountID.flatMap(service.connection) }

    private var statusText: (String, Color)? {
        guard let id = resolution.accountID else { return nil }
        if let problem = connection?.snapshot.problem {
            return (problem.title, problem.needsSignIn ? .orange : .yellow)
        }
        if let login = connection?.snapshot.value?.login { return ("Signed in as \(login)", .green) }
        guard id == .gitHubCLI else { return nil }
        if service.cliExecutable == nil { return ("GitHub CLI not found: brew install gh", .secondary) }
        if let user = service.cliUser { return (user.isEmpty ? "GitHub CLI signed in" : "GitHub CLI: \(user)", .blue) }
        return ("GitHub CLI not signed in: run gh auth login", .orange)
    }

    private var refreshInfo: String {
        let limit = connection?.rateLimit.map {
            " This account has \($0.remaining.formatted()) of \($0.limit.formatted()) GraphQL points left this hour."
        }
        return "Only while the widget is on screen. One request covers every block, and the contribution calendar "
            + "refreshes every 30 minutes." + (limit ?? "")
    }

    /// The offered intervals; one set by hand in `config.json` is listed too.
    private var refreshChoices: [Int] {
        Set(GitHubSettings.refreshMinuteChoices + [settings.refresh.minutes].compactMap(\.self)).sorted()
    }
}

/// Repositories seen in what the widget fetched, to offer as choices.
enum GitHubSuggestions {
    static func repositories(in snapshot: GitHubSnapshot?) -> [String] {
        guard let snapshot else { return [] }
        let names =
            snapshot.searches.values.flatMap(\.items).map(\.repository)
            + snapshot.repositories.values.compactMap { $0?.name }
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }
}

/// Which repositories and owners the widget's searches look in: everywhere, or only these.
private struct GitHubRepositoryFilterEditor: View {
    @Binding var entries: [String]
    let suggestions: [String]
    @State private var isAdding = false

    var body: some View {
        LabeledContent {
            Text(entries.isEmpty ? "Everywhere" : plural(entries.count, "filter"))
                .foregroundStyle(.secondary)
        } label: {
            InfoLabel(
                "Repositories",
                info: "Pull requests and issues only from these. Add owner/name for one repository, or an owner for "
                    + "everything a user or organization owns. Empty for anywhere. Repository blocks show their own "
                    + "repository whatever this says.")
        }
        ForEach(entries, id: \.self) { entry in
            HStack {
                Image(systemName: entry.contains("/") ? "book.closed" : "person.2")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(entry)
                Spacer()
                Button("Remove", systemImage: "minus.circle.fill") { entries.removeAll { $0 == entry } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        if entries.count < GitHubSettings.maximumFilterEntries {
            HStack {
                Spacer()
                Button("Add…") { isAdding = true }
                    .controlSize(.small)
                    .popover(isPresented: $isAdding, arrowEdge: .bottom) {
                        GitHubRepositoryEntry(
                            prompt: "cli/cli, or an owner like apple", action: "Add", suggestions: unusedSuggestions,
                            normalize: GitHubSettings.normalizedFilterEntry
                        ) { entry in
                            entries.append(entry)
                            isAdding = false
                        }
                    }
            }
        }
    }

    private var unusedSuggestions: [String] {
        let used = Set(entries.map { $0.lowercased() })
        return suggestions.filter { !used.contains($0.lowercased()) }
    }

}

/// Typing or picking a repository, in a popover so the inspector's form never opens with a field in focus.
/// Escape or a click outside closes it.
private struct GitHubRepositoryEntry: View {
    let prompt: String
    let action: String
    var initial = ""
    let suggestions: [String]
    let normalize: (String) -> String?
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // A plain example prompt: words like "name" make AppKit offer contact AutoFill here.
                TextField("Repository", text: $draft, prompt: Text(prompt))
                    .labelsHidden()
                    .textContentType(nil)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    .onSubmit(submit)
                Button(action, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalize(draft) == nil)
            }
            if !suggestions.isEmpty {
                Text("Seen in this widget").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(suggestions, id: \.self) { name in
                            Button {
                                commit(name)
                            } label: {
                                Label(name, systemImage: "book.closed")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(12)
        .frame(width: 280)
        .onAppear {
            draft = initial
            isFocused = true
        }
    }

    private func submit() {
        guard let entry = normalize(draft) else { return }
        commit(entry)
    }
}

/// One GitHub block's options, as sections of the inspector's form.
private struct GitHubBlockOptionsEditor: View {
    let block: GitHubBlock
    @Binding var settings: GitHubSettings

    var body: some View {
        switch block {
        case .summary:
            Section {
                Text("Counts follow the Review Requests, Your Pull Requests, Issues and Inbox blocks' options.")
                    .foregroundStyle(.secondary)
            }
        case .reviewRequests:
            Section {
                Toggle(isOn: $settings.blockOptions.reviewRequests.includesTeamRequests) {
                    InfoLabel("Include team requests", info: "Reviews asked of a team you're on, as well as of you.")
                }
            }
            GitHubListOptionsEditor(options: $settings.blockOptions.reviewRequests.list)
        case .pullRequests:
            Section {
                Toggle("Include drafts", isOn: $settings.blockOptions.pullRequests.includesDrafts)
            }
            GitHubListOptionsEditor(options: $settings.blockOptions.pullRequests.list)
        case .issues:
            Section {
                Picker("Issues", selection: $settings.blockOptions.issues.scope) {
                    ForEach(GitHubIssueScope.allCases) { Text($0.title).tag($0) }
                }
            }
            GitHubListOptionsEditor(options: $settings.blockOptions.issues.list)
        case .notifications:
            Section {
                Toggle(isOn: $settings.blockOptions.notifications.participatingOnly) {
                    InfoLabel(
                        "Only threads you take part in",
                        info: "Mentions, reviews asked of you and threads you commented on, not everything you watch.")
                }
                Toggle(isOn: $settings.blockOptions.notifications.includesCIActivity) {
                    InfoLabel("Include workflow runs", info: "GitHub Actions runs finishing. Off, as there are many.")
                }
            }
            GitHubListOptionsEditor(options: $settings.blockOptions.notifications.list)
        case .contributions:
            Section {
                Stepper(
                    value: $settings.blockOptions.contributions.weeks, in: GitHubContributionOptions.weekRange, step: 4
                ) {
                    Text("Last \(settings.blockOptions.contributions.weeks) weeks")
                }
                Toggle("Show the streak", isOn: $settings.blockOptions.contributions.showsStreak)
            }
        case .status:
            Section {
                Toggle(isOn: $settings.blockOptions.status.showsMaintenance) {
                    InfoLabel("Include planned maintenance", info: "From githubstatus.com.")
                }
            }
        case .repository(let id):
            GitHubRepositoryBlockEditor(id: id, settings: $settings)
        }
    }
}

private struct GitHubListOptionsEditor: View {
    @Binding var options: GitHubListOptions

    var body: some View {
        Section {
            Stepper(value: $options.maximumRows, in: GitHubListOptions.rowCountRange) {
                Text("Up to \(options.maximumRows) rows")
            }
            Toggle(isOn: $options.hidesWhenEmpty) {
                InfoLabel("Hide when empty", info: "Takes no room while there's nothing in it.")
            }
        }
    }
}

/// Which repository a Repository block shows, and what of it.
private struct GitHubRepositoryBlockEditor: View {
    let id: UUID
    @Binding var settings: GitHubSettings
    @Environment(GitHubService.self) private var service
    @Environment(AccountStore.self) private var accounts
    @State private var isChoosing = false

    var body: some View {
        Section {
            LabeledContent {
                Button(repository ?? "Choose…") { isChoosing = true }
                    .controlSize(.small)
                    .popover(isPresented: $isChoosing, arrowEdge: .bottom) {
                        GitHubRepositoryEntry(
                            prompt: "cli/cli", action: "Show", initial: repository ?? "", suggestions: suggestions,
                            normalize: GitHubSettings.normalizedRepository
                        ) { name in
                            var options = settings.repositoryOptions(id)
                            options.repository = name
                            settings.setRepositoryOptions(options, for: id)
                            isChoosing = false
                        }
                    }
            } label: {
                InfoLabel("Repository", info: "Any repository the account can see, such as cli/cli.")
            }
        }
        Section {
            Toggle("Show the default branch", isOn: option(\.showsBranch))
            Toggle("Show the latest release", isOn: option(\.showsRelease))
            Toggle("Show pull requests, issues and stars", isOn: option(\.showsCounts))
        }
    }

    private var repository: String? { settings.repositoryOptions(id).repository }

    private var suggestions: [String] {
        let connection = accounts.resolve(settings.account, at: .gitHub).accountID.flatMap(service.connection)
        return GitHubSuggestions.repositories(in: connection?.snapshot.value)
    }

    private func option(_ keyPath: WritableKeyPath<GitHubRepositoryBlockOptions, Bool>) -> Binding<Bool> {
        Binding {
            settings.repositoryOptions(id)[keyPath: keyPath]
        } set: { value in
            var options = settings.repositoryOptions(id)
            options[keyPath: keyPath] = value
            settings.setRepositoryOptions(options, for: id)
        }
    }
}
