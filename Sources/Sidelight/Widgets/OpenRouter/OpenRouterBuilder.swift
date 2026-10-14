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
        case .summary: "How many models there are, when they were synced, and a refresh button."
        case .list: "Models in the order and filter you choose, with a way to see them all."
        case .balance: "An account's balance, and what it spent each day. Needs an account with a management key."
        }
    }
}

extension OpenRouterSettings: BlockBuiltWidget {
    static let presets = OpenRouterPreset.allCases.map { preset in
        BlockPreset<OpenRouterBlock>(
            id: preset.rawValue, title: preset.title, systemImage: preset.systemImage, summary: preset.summary,
            blocks: preset.blocks)
    }

    static func options(for block: OpenRouterBlock, settings: Binding<OpenRouterSettings>) -> some View {
        OpenRouterBlockOptionsEditor(block: block, settings: settings)
    }

    static func widgetOptions(settings: Binding<OpenRouterSettings>) -> some View {
        OpenRouterWidgetOptions(settings: settings)
    }

    static let addableBlocks = [
        AddableBlock(
            id: "list", title: "Model list", systemImage: "list.bullet",
            blurb: "Models in an order and filter of your choice. Add one for each list."),
        AddableBlock(
            id: "balance", title: "Balance", systemImage: "creditcard",
            blurb: "An account's balance and spending. Add one for each account you want to see."),
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
                info: "One public catalogue for every OpenRouter widget, synced only while one shows models. No key "
                    + "needed.")
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
        Picker(selection: $settings.glance) {
            ForEach(OpenRouterGlance.allCases) { Text($0.title).tag($0) }
        } label: {
            InfoLabel("Minimal and bar show", info: glanceCaption)
        }
    }

    private var glanceCaption: String {
        switch settings.glance {
        case .automatic: "The balance if the first block is a Balance block, otherwise the newest model."
        case .newest, .count: "Of the first list's models. Clicking it shows every model in place of the panel."
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

/// One block's options.
private struct OpenRouterBlockOptionsEditor: View {
    let block: OpenRouterBlock
    @Binding var settings: OpenRouterSettings

    var body: some View {
        switch block {
        case .summary:
            SettingsCaption("Which models it counts.")
            OpenRouterFilterEditor(filter: $settings.summary.filter)
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Reads")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), alignment: .leading)], alignment: .leading) {
                ForEach(choices(OpenRouterModality.knownInputs, service.catalogue.value?.inputs, chosen: filter.inputs))
                { input in
                    Toggle(input.title, isOn: reads(input))
                        .toggleStyle(.checkbox)
                }
            }
        }
        Toggle("Nothing else", isOn: $filter.isExact)
            .disabled(filter.isAll)
        SettingsCaption(filter.explanation)
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

/// A Model list's title, order, filter and rows.
private struct OpenRouterModelListEditor: View {
    let id: UUID
    @Binding var settings: OpenRouterSettings

    var body: some View {
        let options = settings.listOptions(id)
        TextField(
            "Title",
            text: Binding {
                options.title ?? ""
            } set: { title in
                update { $0.title = title.isEmpty ? nil : title }
            },
            prompt: Text("None")
        )
        .textFieldStyle(.roundedBorder)
        Picker("Order", selection: option(\.sort)) {
            ForEach(OpenRouterModelSort.allCases) { Text($0.title).tag($0) }
        }
        SettingsCaption("Latest added is when OpenRouter added a model, not when it was released.")
        Divider()
        OpenRouterFilterEditor(filter: option(\.filter))
        Divider()
        Picker("Rows", selection: option(\.density)) {
            ForEach(OpenRouterRowDensity.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        SettingsCaption(densityCaption(options.density))
        Stepper(value: option(\.maximumRows), in: OpenRouterModelListOptions.rowCountRange) {
            Text("Up to \(options.maximumRows) models")
        }
        Toggle("Mark models being retired", isOn: option(\.showsRetiring))
        SettingsCaption("In detail rows, when OpenRouter has announced a date. Compact sizes show lean rows.")
    }

    private func densityCaption(_ density: OpenRouterRowDensity) -> String {
        switch density {
        case .lean: "The name and when it was added."
        case .standard: "Also its ID and prices per million input and output tokens."
        case .detail: "Also its context window, what it reads and writes, and badges."
        }
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

/// A Balance block's title, which account it reads, and its chart.
private struct OpenRouterBalanceEditor: View {
    let id: UUID
    @Binding var settings: OpenRouterSettings
    @Environment(OpenRouterService.self) private var service
    @Environment(AccountStore.self) private var accounts

    var body: some View {
        let options = settings.balanceOptions(id)
        TextField(
            "Title",
            text: Binding {
                options.title ?? ""
            } set: { title in
                update { $0.title = title.isEmpty ? nil : title }
            },
            prompt: Text("Account balance")
        )
        .textFieldStyle(.roundedBorder)
        SettingsCaption("Tells accounts apart when the widget shows more than one.")

        Divider()
        AccountPicker(provider: .openRouter, selection: option(\.account))

        Divider()
        Toggle("Show spending by day", isOn: option(\.chart.isShown))
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
            SettingsCaption(
                "Completed days in UTC: today isn't over yet. What other providers bill through your own keys "
                    + "(BYOK) is listed apart, never added. The balance is always the account's.")
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
