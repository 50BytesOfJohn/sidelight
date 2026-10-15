import SidelightCore
import SwiftUI

extension OpenRouterBlock: DescribedBlock {
    var title: String {
        switch self {
        case .summary: "Summary"
        case .list: "Model list"
        case .balance: "Balance"
        }
    }

    var systemImage: String {
        switch self {
        case .summary: "number"
        case .list: "list.bullet"
        case .balance: "creditcard"
        }
    }

    var blurb: String {
        switch self {
        case .summary: "How many models there are, when they last synced, and a refresh button."
        case .list: "Models in the order and filter you choose. Clicking it shows them all."
        case .balance: "An account's balance and daily spending. Needs an account with a management key."
        }
    }
}

extension OpenRouterSettings: BlockBuiltWidget {
    static let presets = OpenRouterPreset.allCases.map { preset in
        BlockPreset<OpenRouterBlock>(id: preset.rawValue, title: preset.title, blocks: preset.blocks)
    }

    static func options(for block: OpenRouterBlock, settings: Binding<OpenRouterSettings>) -> some View {
        OpenRouterBlockOptionsEditor(block: block, settings: settings)
    }

    static func widgetOptions(settings: Binding<OpenRouterSettings>) -> some View {
        OpenRouterWidgetOptions(settings: settings)
    }

    static let addableBlocks = [
        AddableBlock(id: "list", title: "Model list", systemImage: "list.bullet"),
        AddableBlock(id: "balance", title: "Balance", systemImage: "creditcard"),
    ]

    mutating func addBlock(_ id: AddableBlock.ID) -> OpenRouterBlock? {
        switch id {
        case "list": addListBlock()
        case "balance": addBalanceBlock()
        default: nil
        }
    }

    func title(of block: OpenRouterBlock) -> String {
        switch block {
        case .summary: block.title
        case .list(let id): listOptions(id).title ?? OpenRouterPreset(listID: id)?.title ?? block.title
        case .balance(let id): balanceOptions(id).title ?? block.title
        }
    }
}

/// The Widgets window's settings for an OpenRouter widget: a ready-made layout, and the options for the whole widget.
/// Blocks are arranged in the builder.
struct OpenRouterSettingsEditor: View {
    @Binding var settings: OpenRouterSettings

    var body: some View {
        BlockPresetPicker(settings: $settings)
        OpenRouterWidgetOptions(settings: $settings)
    }
}

/// How often models sync and balances refresh, and what the smallest sizes show.
private struct OpenRouterWidgetOptions: View {
    @Binding var settings: OpenRouterSettings

    var body: some View {
        Picker(selection: $settings.sync) {
            Text("Manually").tag(RefreshCadence.manual)
            ForEach(syncChoices, id: \.self) { minutes in
                Text(OpenRouterSettings.syncTitle(minutes: minutes)).tag(RefreshCadence.minutes(minutes))
            }
        } label: {
            InfoLabel(
                "Sync models",
                info: "Every OpenRouter widget shares one public catalogue, synced only while one of them shows "
                    + "models. No key needed.")
        }
        Picker(selection: $settings.refresh) {
            Text("Manually").tag(RefreshCadence.manual)
            ForEach(refreshChoices, id: \.self) { minutes in
                Text("Every \(minutes) minutes").tag(RefreshCadence.minutes(minutes))
            }
        } label: {
            InfoLabel(
                "Refresh balances",
                info: settings.refresh == .manual
                    ? "Fetched once, then whenever you click refresh."
                    : "Only while a balance is on screen. Spending changes once a day, so Sidelight fetches it after "
                        + "midnight UTC.")
        }
        ExpandableRow(title: "Advanced") {
            Picker(selection: $settings.glance) {
                ForEach(OpenRouterGlance.allCases) { Text($0.title).tag($0) }
            } label: {
                InfoLabel("Minimal and bar show", info: glanceInfo)
            }
        }
    }

    private var glanceInfo: String {
        switch settings.glance {
        case .automatic: "The balance if the first block is a Balance block, otherwise the newest model."
        case .newest, .count: "From the first list. Clicking it shows every model in place of the panel."
        case .balance: "The first Balance block's."
        }
    }

    /// The offered intervals; one set by hand in `config.json` is listed too.
    private var syncChoices: [Int] {
        Set(OpenRouterSettings.syncMinuteChoices + [settings.sync.minutes].compactMap(\.self)).sorted()
    }

    private var refreshChoices: [Int] {
        Set(OpenRouterSettings.refreshMinuteChoices + [settings.refresh.minutes].compactMap(\.self)).sorted()
    }
}

/// One block's options, as sections of the inspector's form.
private struct OpenRouterBlockOptionsEditor: View {
    let block: OpenRouterBlock
    @Binding var settings: OpenRouterSettings

    var body: some View {
        switch block {
        case .summary:
            Section("Counts") {
                OpenRouterFilterEditor(filter: $settings.summary.filter)
            }
        case .list(let id):
            OpenRouterModelListEditor(id: id, settings: $settings)
        case .balance(let id):
            OpenRouterBalanceEditor(id: id, settings: $settings)
        }
    }
}

/// Which models a list shows or the summary counts, as OpenRouter's catalogue filters them: what they produce, what
/// they read, and whether nothing else.
private struct OpenRouterFilterEditor: View {
    @Binding var filter: OpenRouterModelFilter
    @Environment(OpenRouterService.self) private var service

    var body: some View {
        Picker("Produces", selection: $filter.output) {
            Text("Anything").tag(OpenRouterModality?.none)
            ForEach(
                choices(
                    OpenRouterModality.knownOutputs, service.catalogue.value?.outputs,
                    chosen: filter.output.map { [$0] } ?? [])
            ) {
                Label($0.title, systemImage: $0.systemImage).tag(Optional($0))
            }
        }
        let inputs = choices(OpenRouterModality.knownInputs, service.catalogue.value?.inputs, chosen: filter.inputs)
        // One menu to tick any number of inputs in, so the row stays one line however many OpenRouter lists.
        LabeledContent("Reads") {
            Menu(readsTitle(inputs)) {
                ForEach(inputs) { input in
                    Toggle(isOn: reads(input)) { Label(input.title, systemImage: input.systemImage) }
                }
            }
            .fixedSize()
        }
        Toggle(isOn: $filter.isExact) {
            InfoLabel("Nothing else", info: "Leaves out models that also produce or read anything not chosen here.")
        }
        .disabled(filter.isAll)
    }

    /// "Anything", or the ticked inputs in the menu's order: "Text, Image".
    private func readsTitle(_ inputs: [OpenRouterModality]) -> String {
        let ticked = inputs.filter(filter.inputs.contains).map(\.title)
        return ticked.isEmpty ? "Anything" : ticked.joined(separator: ", ")
    }

    /// The kinds OpenRouter lists, any it added since, and one chosen before that it no longer lists.
    private func choices(
        _ known: [OpenRouterModality], _ listed: [OpenRouterModality]?, chosen: Set<OpenRouterModality>
    ) -> [OpenRouterModality] {
        OpenRouterModality.ordered(known + (listed ?? []) + chosen, as: known)
    }

    private func reads(_ input: OpenRouterModality) -> Binding<Bool> {
        Binding {
            filter.inputs.contains(input)
        } set: { isOn in
            if isOn { filter.inputs.insert(input) } else { filter.inputs.remove(input) }
        }
    }
}

/// A Model list's title, order and rows, then its filter.
private struct OpenRouterModelListEditor: View {
    let id: UUID
    @Binding var settings: OpenRouterSettings

    var body: some View {
        let options = settings.listOptions(id)
        Section {
            TextField(
                "Title",
                text: Binding {
                    options.title ?? ""
                } set: { title in
                    update { $0.title = title.isEmpty ? nil : title }
                },
                prompt: Text("None")
            )
            Picker(selection: option(\.sort)) {
                ForEach(OpenRouterModelSort.allCases) { Text($0.title).tag($0) }
            } label: {
                InfoLabel("Order", info: "Latest added is when OpenRouter added a model, not when it was released.")
            }
            Picker(selection: option(\.density)) {
                ForEach(OpenRouterRowDensity.allCases) { Text($0.title).tag($0) }
            } label: {
                InfoLabel("Rows", info: densityInfo(options.density))
            }
            Stepper(value: option(\.maximumRows), in: OpenRouterModelListOptions.rowCountRange) {
                Text("Up to \(options.maximumRows) models")
            }
            if options.density == .detail {
                Toggle(isOn: option(\.showsRetiring)) {
                    InfoLabel("Mark models being retired", info: "Once OpenRouter announces a date.")
                }
            }
        }
        Section("Filter") {
            OpenRouterFilterEditor(filter: option(\.filter))
        }
    }

    private func densityInfo(_ density: OpenRouterRowDensity) -> String {
        let rows =
            switch density {
            case .lean: "The name and when it was added."
            case .standard: "Also the ID and prices per million input and output tokens."
            case .detail: "Also the context window, what it reads and writes, and badges."
            }
        return rows + " Compact sizes always show lean rows."
    }

    private func update(_ change: (inout OpenRouterModelListOptions) -> Void) {
        var options = settings.listOptions(id)
        change(&options)
        settings.setListOptions(options, for: id)
    }

    private func option<Value>(_ keyPath: WritableKeyPath<OpenRouterModelListOptions, Value>) -> Binding<Value> {
        Binding {
            settings.listOptions(id)[keyPath: keyPath]
        } set: { value in
            update { $0[keyPath: keyPath] = value }
        }
    }
}

/// A Balance block's title and account, then its chart.
private struct OpenRouterBalanceEditor: View {
    let id: UUID
    @Binding var settings: OpenRouterSettings
    @Environment(OpenRouterService.self) private var service
    @Environment(AccountStore.self) private var accounts

    var body: some View {
        let options = settings.balanceOptions(id)
        Section {
            TextField(
                text: Binding {
                    options.title ?? ""
                } set: { title in
                    update { $0.title = title.isEmpty ? nil : title }
                },
                prompt: Text("Account balance")
            ) {
                InfoLabel("Title", info: "Tells accounts apart when the widget shows more than one.")
            }
            AccountPicker(provider: .openRouter, selection: option(\.account))
        }
        Section {
            Toggle(isOn: option(\.chart.isShown)) {
                InfoLabel(
                    "Spending by day",
                    info: "Completed days in UTC. Spending other providers bill through your own keys (BYOK) is listed "
                        + "apart, never added. The balance is always the account's.")
            }
            if options.chart.isShown {
                Picker("Days", selection: option(\.chart.days)) {
                    ForEach(dayChoices(options.chart.days), id: \.self) { Text("\($0) days").tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Spending of", selection: option(\.chart.scope)) {
                    Text("The account").tag(OpenRouterChartScope.account)
                    Text("One key").tag(OpenRouterChartScope.key)
                }
                if options.chart.scope == .key, let account {
                    OpenRouterKeyPicker(account: account, chart: option(\.chart))
                        // Another account lists other keys.
                        .id(account.id)
                }
            }
        }
    }

    /// The account the block reads, once the service has it.
    private var account: OpenRouterAccount? {
        accounts.resolve(settings.balanceOptions(id).account, at: .openRouter).accountID.flatMap(service.account)
    }

    private func dayChoices(_ days: Int) -> [Int] {
        Set(OpenRouterSpendChartSettings.dayChoices + [days]).sorted()
    }

    private func update(_ change: (inout OpenRouterBalanceOptions) -> Void) {
        var options = settings.balanceOptions(id)
        change(&options)
        settings.setBalanceOptions(options, for: id)
    }

    private func option<Value>(_ keyPath: WritableKeyPath<OpenRouterBalanceOptions, Value>) -> Binding<Value> {
        Binding {
            settings.balanceOptions(id)[keyPath: keyPath]
        } set: { value in
            update { $0[keyPath: keyPath] = value }
        }
    }
}
