import SidelightCore
import SwiftUI

extension AIUsageBlock: DescribedBlock {
    var title: String { provider.title }

    var systemImage: String { "gauge.with.dots.needle.67percent" }

    var logo: String? { provider.agent.logoAsset }

    var blurb: String { provider.blurb }
}

extension AIUsageProvider {
    /// What its block shows, in a line.
    var blurb: String {
        switch self {
        case .codex: "Your ChatGPT plan's limits, as Codex reports them."
        case .claudeCode: "A Claude account's session and weekly limits. Add one for each account."
        case .cursor: "Your Cursor plan's included usage over the billing cycle."
        }
    }
}

extension AIUsagePreset {
    var title: String {
        switch self {
        case .everyAgent: "Every agent"
        case .codexAndClaude: "Codex and Claude"
        }
    }

    var systemImage: String {
        switch self {
        case .everyAgent: "square.stack.3d.up"
        case .codexAndClaude: "terminal"
        }
    }

    var summary: String {
        switch self {
        case .everyAgent: "Codex, Claude Code and Cursor"
        case .codexAndClaude: "The two that need nothing connected"
        }
    }
}

extension AIUsageSettings: BlockBuiltWidget {
    static let presets = AIUsagePreset.allCases.map { preset in
        BlockPreset<AIUsageBlock>(
            id: preset.rawValue, title: preset.title, systemImage: preset.systemImage, summary: preset.summary,
            blocks: preset.blocks)
    }

    static func options(for block: AIUsageBlock, settings: Binding<AIUsageSettings>) -> some View {
        AIUsageBlockOptionsEditor(block: block, settings: settings)
    }

    static func widgetOptions(settings: Binding<AIUsageSettings>) -> some View {
        AIUsageWidgetOptions(settings: settings)
    }

    static let addableBlocks = AIUsageProvider.allCases.map { provider in
        AddableBlock(
            id: provider.rawValue, title: provider.title, systemImage: "gauge.with.dots.needle.67percent",
            logo: provider.agent.logoAsset, blurb: provider.blurb)
    }

    mutating func addBlock(_ id: AddableBlock.ID) -> AIUsageBlock? {
        AIUsageProvider(rawValue: id).map { addBlock($0) }
    }

    func title(of block: AIUsageBlock) -> String {
        options(block).label ?? block.title
    }
}

/// The Widgets window's settings for an AI Usage widget: a ready-made layout, and the options for the whole widget.
/// Blocks, with their accounts and labels, are arranged in the builder.
struct AIUsageSettingsEditor: View {
    @Binding var settings: AIUsageSettings

    var body: some View {
        BlockPresetPicker(settings: $settings)
        AIUsageWidgetOptions(settings: $settings)
    }
}

/// How limits read, and when Claude and Cursor usage is fetched, for every block. Each Claude account fetches once,
/// however many blocks or widgets show it, so it's one choice for the whole widget.
private struct AIUsageWidgetOptions: View {
    @Binding var settings: AIUsageSettings

    var body: some View {
        Picker(selection: $settings.reading) {
            ForEach(UsageReading.allCases) { Text($0.title).tag($0) }
        } label: {
            InfoLabel(
                "Limits show",
                info: settings.reading == .used
                    ? "Meters fill as you use each agent, and the tick moves with the window's time. A meter past "
                        + "its tick runs out before the reset."
                    : "Like Codex's /status. Meters drain as you use each agent, and the tick drains with the "
                        + "window's time. A meter below its tick runs out before the reset.")
        }
        .pickerStyle(.segmented)
        Toggle(isOn: $settings.showsOtherLimits) {
            InfoLabel(
                "Show other limits",
                info: "Each agent's other windows or pools next to its main one, in regular and compact cards.")
        }
        if has(.claudeCode) {
            Divider()
            AnthropicRefreshPicker(
                title: "Refresh Claude from Anthropic", isOn: $settings.refreshesClaudeFromAnthropic,
                minutes: $settings.claudeRefreshMinutes)
        }
        if has(.cursor) {
            Divider()
            CursorFetchPicker(isOn: $settings.refreshesCursor, minutes: $settings.cursorRefreshMinutes)
        }
    }

    /// Whether any block, shown or hidden, shows `provider`.
    private func has(_ provider: AIUsageProvider) -> Bool {
        settings.blocks.entries.contains { $0.block.provider == provider }
    }
}

/// One block's label, its account for an agent with accounts, and where its numbers come from.
private struct AIUsageBlockOptionsEditor: View {
    let block: AIUsageBlock
    @Binding var settings: AIUsageSettings

    var body: some View {
        TextField("Label", text: label, prompt: Text(block.provider.title))
            .textFieldStyle(.roundedBorder)
        SettingsCaption("Shown in place of the agent's name, to tell its blocks apart.")
        Divider()
        if block.provider.hasAccounts {
            AccountPicker(provider: block.provider.accountProvider, selection: option(\.account))
        }
        switch block.provider {
        case .codex:
            CodexSourceStatus()
        case .claudeCode:
            let account = settings.options(block).account
            if settings.refreshesClaudeFromAnthropic {
                AnthropicFetchStatus(account: account)
            }
            StatusLineSetup(account: account)
        case .cursor:
            if settings.refreshesCursor {
                CursorFetchStatus()
            } else {
                SettingsCaption(
                    "Cursor keeps no usage on this Mac. Turn on Fetch usage from Cursor in the widget's "
                        + "options to see it.")
            }
        }
    }

    private var label: Binding<String> {
        Binding {
            settings.options(block).label ?? ""
        } set: { label in
            let trimmed = label.trimmingCharacters(in: .whitespaces)
            update { $0.label = trimmed.isEmpty ? nil : label }
        }
    }

    private func update(_ change: (inout AIUsageBlockOptions) -> Void) {
        var options = settings.options(block)
        change(&options)
        settings.setOptions(options, for: block)
    }

    private func option<Value>(_ keyPath: WritableKeyPath<AIUsageBlockOptions, Value>) -> Binding<Value> {
        Binding {
            settings.options(block)[keyPath: keyPath]
        } set: { value in
            update { $0[keyPath: keyPath] = value }
        }
    }
}
