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
        case .claudeCode: "A Claude account's session and weekly limits. Add one per account."
        case .cursor: "Your Cursor plan's included usage over the billing cycle."
        case .openCode: "OpenCode Go's 5-hour, weekly and monthly limits, and Console budgets. Add one per account."
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
}

extension AIUsageSettings: BlockBuiltWidget {
    static let presets = AIUsagePreset.allCases.map { preset in
        BlockPreset<AIUsageBlock>(id: preset.rawValue, title: preset.title, blocks: preset.blocks)
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
            logo: provider.agent.logoAsset)
    }

    mutating func addBlock(_ id: AddableBlock.ID) -> AIUsageBlock? {
        AIUsageProvider(rawValue: id).map { addBlock($0) }
    }

    func title(of block: AIUsageBlock) -> String {
        options(block).label ?? block.title
    }

    func variants(of block: AIUsageBlock) -> [BlockVariant] {
        AIUsageBlockVariant.allCases.map { variant in
            BlockVariant(id: variant.rawValue, title: variant.title, summary: variant.summary(for: block.provider))
        }
    }

    func variantID(of block: AIUsageBlock) -> String? {
        options(block).variant.rawValue
    }

    mutating func setVariant(_ id: String, of block: AIUsageBlock) {
        guard let variant = AIUsageBlockVariant(rawValue: id) else { return }
        var options = options(block)
        options.variant = variant
        setOptions(options, for: block)
    }

    /// Whether any block, shown or hidden, shows the limit closest to running out, the only look with other limits
    /// to show beside it.
    var hasClosestLimitBlock: Bool {
        blocks.entries.contains { options($0.block).variant == .closestLimit }
    }
}

extension AIUsageBlockVariant {
    var title: String {
        switch self {
        case .closestLimit: "Closest limit"
        case .eachLimit: "Each limit"
        case .line: "One line"
        case .tide: "Tide (experimental)"
        }
    }

    /// What a block in this look shows of `provider`'s limits.
    func summary(for provider: AIUsageProvider) -> String {
        switch (self, provider) {
        case (.closestLimit, _):
            "Leads with whichever limit is closest to running out, with a forecast when it runs out early. The "
                + "others can show small beside it."
        case (.eachLimit, .claudeCode):
            "A meter for the 5-hour session and one for the week, always in that order."
        case (.eachLimit, .codex):
            "A meter for each limit Codex reports, shortest window first, always in that order."
        case (.eachLimit, .cursor):
            "A meter for each of your plan's usage pools, always in the same order."
        case (.eachLimit, .openCode):
            "A meter for Go's 5 hours, week and month, then one for each budget, always in that order."
        case (.line, _):
            "The closest limit on a single line, with a hairline meter and when it resets. The smallest look, for "
                + "keeping many agents or accounts in view."
        case (.tide, _):
            "A single line that is its own meter: it fills as the closest limit is used, with a tick for the "
                + "window's time. The other limits run as hairlines along its bottom edge."
        }
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

/// How limits read, and when Claude, Cursor and OpenCode usage is fetched, for every block. Each Claude or OpenCode
/// account fetches once, however many blocks or widgets show it, so it's one choice for the whole widget.
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
        if settings.hasClosestLimitBlock {
            Toggle(isOn: $settings.showsOtherLimits) {
                InfoLabel(
                    "Show other limits",
                    info: "Each agent's other windows or pools next to its closest limit, in regular and compact "
                        + "cards. Blocks showing each limit already show them all.")
            }
        }
        if has(.claudeCode) {
            AnthropicRefreshPicker(
                title: "Refresh Claude from Anthropic", isOn: $settings.refreshesClaudeFromAnthropic,
                minutes: $settings.claudeRefreshMinutes)
        }
        if has(.cursor) {
            CursorFetchPicker(isOn: $settings.refreshesCursor, minutes: $settings.cursorRefreshMinutes)
        }
        if has(.openCode) {
            OpenCodeFetchPicker(isOn: $settings.refreshesOpenCode, minutes: $settings.openCodeRefreshMinutes)
        }
    }

    /// Whether any block, shown or hidden, shows `provider`.
    private func has(_ provider: AIUsageProvider) -> Bool {
        settings.blocks.entries.contains { $0.block.provider == provider }
    }
}

/// One block's label, its account for an agent with accounts, and where its numbers come from, as a section of the
/// inspector's form.
private struct AIUsageBlockOptionsEditor: View {
    let block: AIUsageBlock
    @Binding var settings: AIUsageSettings

    var body: some View {
        Section { options }
    }

    @ViewBuilder
    private var options: some View {
        TextField(text: label, prompt: Text(block.provider.title)) {
            InfoLabel("Label", info: "Shown in place of the agent's name, to tell its blocks apart.")
        }
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
                SettingsCaption("Cursor keeps no usage on this Mac. Turn on Fetch usage from Cursor in the widget.")
            }
        case .openCode:
            if settings.refreshesOpenCode {
                OpenCodeFetchStatus(account: settings.options(block).account)
            } else {
                SettingsCaption(
                    "OpenCode keeps no usage on this Mac. Turn on Fetch usage from OpenCode in the widget.")
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
