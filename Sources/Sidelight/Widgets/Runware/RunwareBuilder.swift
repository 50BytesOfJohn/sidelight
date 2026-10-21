import SidelightCore
import SwiftUI

extension RunwareBlock: DescribedBlock {
    var title: String {
        switch self {
        case .balance: "Balance"
        case .usage: "Usage"
        case .chart: "Spending chart"
        case .models: "Top models"
        }
    }

    var systemImage: String {
        switch self {
        case .balance: "creditcard"
        case .usage: "gauge.with.dots.needle.33percent"
        case .chart: "chart.bar"
        case .models: "square.stack.3d.up"
        }
    }

    var blurb: String {
        switch self {
        case .balance: "The organization's balance, with free credits apart."
        case .usage: "Spend and requests today, over 7 days and over 30 days."
        case .chart: "Spend or requests by UTC day, today so far included."
        case .models: "The models that spent most over 30 days."
        }
    }
}

extension RunwareSettings: BlockBuiltWidget {
    static let presets = RunwarePreset.allCases.map { preset in
        BlockPreset<RunwareBlock>(id: preset.rawValue, title: preset.title, blocks: preset.blocks)
    }

    static func options(for block: RunwareBlock, settings: Binding<RunwareSettings>) -> some View {
        RunwareBlockOptionsEditor(block: block, settings: settings)
    }

    static func widgetOptions(settings: Binding<RunwareSettings>) -> some View {
        RunwareWidgetOptions(settings: settings)
    }
}

/// The Widgets window's settings for a Runware widget: a ready-made layout, and the options for the whole widget.
struct RunwareSettingsEditor: View {
    @Binding var settings: RunwareSettings

    var body: some View {
        BlockPresetPicker(settings: $settings)
        RunwareWidgetOptions(settings: $settings)
    }
}

/// Whose Runware organization, how it's doing, and how often to ask.
private struct RunwareWidgetOptions: View {
    @Binding var settings: RunwareSettings
    @Environment(RunwareService.self) private var service
    @Environment(AccountStore.self) private var accounts

    var body: some View {
        AccountPicker(provider: .runware, selection: $settings.account)
        if let (text, color) = statusText {
            StatusRow(color: color, text: text) {
                Spacer(minLength: 0)
                if let account, account.details.value != nil || account.details.problem != nil {
                    Button("Refresh") { service.refreshNow() }
                        .controlSize(.small)
                        .disabled(account.details.isFetching)
                }
            }
        }
        ExpandableRow(title: "Advanced") {
            Picker(selection: $settings.refresh) {
                Text("Manually").tag(RefreshCadence.manual)
                ForEach(refreshChoices, id: \.self) { minutes in
                    Text("Every \(minutes) minutes").tag(RefreshCadence.minutes(minutes))
                }
            } label: {
                InfoLabel(
                    "Refresh",
                    info: "Only while the widget is on screen. Activity refreshes at most every "
                        + "\(RunwareSettings.activityMinimumMinutes) minutes. Sidelight's reads count against your "
                        + "organization's rate limit, shared with your apps.")
            }
        }
    }

    private var resolution: AccountResolution { accounts.resolve(settings.account, at: .runware) }

    private var account: RunwareAccount? { resolution.accountID.flatMap(service.account) }

    /// The organization once fetched, otherwise what's known of the CLI.
    private var statusText: (String, Color)? {
        guard let id = resolution.accountID else { return nil }
        if let problem = account?.details.problem { return (problem.title, problem.needsKey ? .orange : .yellow) }
        if let details = account?.details.value { return (details.organizationName ?? "Connected", .green) }
        guard id == .runwareCLI else { return nil }
        switch service.cliStatus {
        case .signedIn: return ("Runware CLI signed in", .blue)
        case .unreadable: return ("Can't read the Runware CLI's settings", .orange)
        case .signedOut, nil:
            if service.cliExecutable == nil { return ("Runware CLI not found", .secondary) }
            return ("Runware CLI not signed in", .orange)
        }
    }

    /// The offered intervals; one set by hand in `config.json` is listed too.
    private var refreshChoices: [Int] {
        Set(RunwareSettings.refreshMinuteChoices + [settings.refresh.minutes].compactMap(\.self)).sorted()
    }
}

/// One block's options, as sections of the inspector's form.
private struct RunwareBlockOptionsEditor: View {
    let block: RunwareBlock
    @Binding var settings: RunwareSettings

    var body: some View {
        switch block {
        case .balance:
            Section {
                TextField(
                    text: Binding {
                        settings.balance.title ?? ""
                    } set: { title in
                        settings.balance.title = title.isEmpty ? nil : title
                    },
                    prompt: Text("Runware · organization")
                ) {
                    InfoLabel("Title", info: "Tells organizations apart when you show more than one.")
                }
                Toggle(isOn: $settings.balance.showsFreeCredits) {
                    InfoLabel(
                        "Show free credits",
                        info: "Listed apart, never added: Runware doesn't say whether the balance includes them.")
                }
            }
        case .usage:
            Section {
                Text("Today, 7 days and 30 days, as Runware totals them.").foregroundStyle(.secondary)
            }
        case .chart:
            Section {
                Picker("Days", selection: $settings.chart.days) {
                    ForEach(dayChoices, id: \.self) { Text("\($0) days").tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Shows", selection: $settings.chart.metric) {
                    ForEach(RunwareChartMetric.allCases) { Text($0.title).tag($0) }
                }
            }
        case .models:
            Section {
                Stepper(value: $settings.models.rowCount, in: RunwareModelsOptions.rowCountRange) {
                    Text("Up to \(settings.models.rowCount) models")
                }
            }
        }
    }

    private var dayChoices: [Int] {
        Set(RunwareChartOptions.dayChoices + [settings.chart.days]).sorted()
    }
}
