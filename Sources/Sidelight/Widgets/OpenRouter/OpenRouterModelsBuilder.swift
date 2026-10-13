import SidelightCore
import SwiftUI

extension OpenRouterModelsBlock: DescribedBlock {
    var title: String {
        switch self {
        case .summary: "Summary"
        case .list: "Model list"
        }
    }

    var systemImage: String {
        switch self {
        case .summary: "number"
        case .list: "list.bullet"
        }
    }

    var blurb: String {
        switch self {
        case .summary: "How many models there are, when they were synced, and a refresh button."
        case .list: "Models in the order and filter you choose, with a way to see them all."
        }
    }
}

extension OpenRouterModelsSettings: BlockBuiltWidget {
    static let presets = OpenRouterModelsPreset.allCases.map { preset in
        BlockPreset<OpenRouterModelsBlock>(
            id: preset.rawValue, title: preset.title, systemImage: preset.systemImage, summary: preset.summary,
            blocks: preset.blocks)
    }

    static func options(for block: OpenRouterModelsBlock, settings: Binding<OpenRouterModelsSettings>) -> some View {
        OpenRouterModelsBlockOptionsEditor(block: block, settings: settings)
    }

    static func widgetOptions(settings: Binding<OpenRouterModelsSettings>) -> some View {
        OpenRouterModelsWidgetOptions(settings: settings)
    }

    static let addableBlocks = [
        AddableBlock(
            id: "list", title: "Model list", systemImage: "list.bullet",
            blurb: "Models in an order and filter of your choice. Add one for each list.")
    ]

    mutating func addBlock(_ id: AddableBlock.ID) -> OpenRouterModelsBlock? {
        id == "list" ? addListBlock() : nil
    }

    func title(of block: OpenRouterModelsBlock) -> String {
        guard case .list(let id) = block else { return block.title }
        return listOptions(id).title ?? OpenRouterModelsPreset(listID: id)?.title ?? block.title
    }
}

/// The Widgets window's settings for an OpenRouter Models widget: a ready-made layout, and the options for the whole
/// widget. Blocks are arranged in the builder.
struct OpenRouterModelsSettingsEditor: View {
    @Binding var settings: OpenRouterModelsSettings

    var body: some View {
        BlockPresetPicker(settings: $settings)
        Divider()
        OpenRouterModelsWidgetOptions(settings: $settings)
    }
}

/// How often the catalogue syncs, and what the smallest sizes show.
private struct OpenRouterModelsWidgetOptions: View {
    @Binding var settings: OpenRouterModelsSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Sync", selection: $settings.sync) {
                Text("Manually").tag(RefreshCadence.manual)
                ForEach(syncChoices, id: \.self) { minutes in
                    Text(OpenRouterModelsSettings.syncTitle(minutes: minutes)).tag(RefreshCadence.minutes(minutes))
                }
            }
            SettingsCaption(
                "One public catalogue for every Models widget, synced only while one is on screen. No key needed.")
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Picker("Minimal and bar show", selection: $settings.glance) {
                ForEach(OpenRouterModelsGlance.allCases) { Text($0.title).tag($0) }
            }
            SettingsCaption("Of the first list's models. Clicking it shows every model in place of the panel.")
        }
    }

    /// The offered intervals; one set by hand in `config.json` is listed too.
    private var syncChoices: [Int] {
        Set(OpenRouterModelsSettings.syncMinuteChoices + [settings.sync.minutes].compactMap(\.self)).sorted()
    }
}

/// One block's options.
private struct OpenRouterModelsBlockOptionsEditor: View {
    let block: OpenRouterModelsBlock
    @Binding var settings: OpenRouterModelsSettings

    var body: some View {
        switch block {
        case .summary:
            Picker("Count", selection: $settings.summary.filter) {
                ForEach(OpenRouterModelFilter.allCases) { Text($0.title).tag($0) }
            }
            SettingsCaption(settings.summary.filter.explanation)
        case .list(let id):
            OpenRouterModelListEditor(id: id, settings: $settings)
        }
    }
}

/// A Model list's title, order, filter and rows.
private struct OpenRouterModelListEditor: View {
    let id: UUID
    @Binding var settings: OpenRouterModelsSettings

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
        Picker("Show", selection: option(\.filter)) {
            ForEach(OpenRouterModelFilter.allCases) { Text($0.title).tag($0) }
        }
        SettingsCaption(options.filter.explanation)
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
