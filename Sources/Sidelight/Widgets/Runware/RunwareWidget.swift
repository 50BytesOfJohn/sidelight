import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let runware = WidgetMetadata(
        title: "Runware",
        systemImage: "photo.stack",
        tint: .pink,
        summary: "Balance, spending and models",
        details: "Your Runware organization's balance and what it's spending, by day and by model, with a model "
            + "browser in details. Uses an API key or the Runware CLI's sign-in. Sidelight only reads: it never runs a "
            + "generation.",
        isBeta: true
    )
}

// MARK: - Widget

struct RunwareWidgetView: View {
    let settings: RunwareSettings
    let layout: WidgetLayout
    @Environment(RunwareService.self) private var service
    @Environment(DetailsPresenter.self) private var details
    @Environment(\.widgetPlacement) private var placement
    @Environment(\.isWidgetPreview) private var isPreview

    var body: some View {
        WidgetClock { now in
            if isPreview {
                // The Widgets window and the builder show what it looks like, with an example marked as one: never an
                // organization's money, and no key is ever read for it.
                RunwareWidgetContent(state: .example(at: now), settings: settings, layout: layout, now: now, open: nil)
            } else {
                AccountGate(reference: settings.account, provider: .runware, layout: layout) { id in
                    if let account = service.account(id) {
                        RunwareWidgetContent(
                            state: RunwareWidgetState(account), settings: settings, layout: layout, now: now,
                            open: open(id))
                    } else {
                        WidgetMessage(
                            title: "Connecting to Runware…", detail: nil, systemImage: "hourglass", layout: layout)
                    }
                }
            }
        }
    }

    /// Opens the account in the details panel, in place of this panel. Only from a real panel.
    private func open(_ account: AccountID) -> ((RunwareDetailsTab) -> Void)? {
        guard let placement else { return nil }
        return { [details] tab in details.open(.runware(account: account, tab: tab), from: placement) }
    }
}

/// What a Runware widget draws from: an account's data as it stands, or an example in previews.
struct RunwareWidgetState {
    let details: RunwareAccountDetails?
    let detailsProblem: RunwareProblem?
    let isFetchingDetails: Bool
    let activity: RunwareActivity?
    let activityProblem: RunwareProblem?
    let isFetchingActivity: Bool
    /// An example in a preview, not anyone's money: it says so.
    let isExample: Bool
    /// Fetches now; `nil` in previews, and with a key Runware rejected, which isn't tried again until it's replaced.
    let refresh: ((_ includingActivity: Bool) -> Void)?

    init(_ account: RunwareAccount) {
        details = account.details.value
        detailsProblem = account.details.problem
        isFetchingDetails = account.details.isFetching
        activity = account.activity.value
        activityProblem = account.activity.problem
        isFetchingActivity = account.activity.isFetching
        isExample = false
        let rejected = detailsProblem?.needsKey == true || activityProblem?.needsKey == true
        refresh = rejected ? nil : { account.refresh(includingActivity: $0) }
    }

    private init(details: RunwareAccountDetails, activity: RunwareActivity) {
        self.details = details
        detailsProblem = nil
        isFetchingDetails = false
        self.activity = activity
        activityProblem = nil
        isFetchingActivity = false
        isExample = true
        refresh = nil
    }

    static func example(at now: Date) -> RunwareWidgetState {
        RunwareWidgetState(details: .example(at: now), activity: .example(at: now))
    }
}

/// A Runware widget's content once it has an account: its blocks, or in the smallest sizes, the balance alone.
struct RunwareWidgetContent: View {
    let state: RunwareWidgetState
    let settings: RunwareSettings
    let layout: WidgetLayout
    let now: Date
    /// `nil` where no details panel can open: previews.
    let open: ((RunwareDetailsTab) -> Void)?
    @Environment(SettingsNavigator.self) private var navigator

    var body: some View {
        if layout.isGlanceable {
            if let details = state.details {
                RunwareGlance(
                    details: details, problem: state.detailsProblem, layout: layout, now: now,
                    isExample: state.isExample, open: open.map { open in { open(.usage) } })
            } else {
                message(problem: state.detailsProblem, isFetching: state.isFetchingDetails, includesActivity: false)
            }
        } else {
            blocks
        }
    }

    @ViewBuilder
    private var blocks: some View {
        let blocks = settings.blocks.shownBlocks
        let needsDetails = settings.showsDetails
        if blocks.isEmpty {
            WidgetMessage(
                title: "No blocks shown", detail: "Choose blocks in this widget's builder.",
                systemImage: "square.stack.3d.up", layout: layout)
        } else if needsDetails ? state.details == nil : state.activity == nil {
            message(
                problem: needsDetails ? state.detailsProblem : state.activityProblem,
                isFetching: needsDetails ? state.isFetchingDetails : state.isFetchingActivity,
                includesActivity: !needsDetails)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.element) { index, block in
                    if index > 0 {
                        HairlineDivider()
                            .padding(.vertical, layout == .regular ? 10 : 7)
                    }
                    view(for: block)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(Motion.layout, value: blocks)
        }
    }

    @ViewBuilder
    private func view(for block: RunwareBlock) -> some View {
        let isCompact = layout == .compact
        switch block {
        case .balance:
            if let details = state.details {
                RunwareBalanceBlock(
                    details: details, problem: state.detailsProblem, isFetching: state.isFetchingDetails,
                    options: settings.balance, isCompact: isCompact, now: now, isExample: state.isExample,
                    refresh: state.refresh.map { refresh in { refresh(settings.showsActivity) } },
                    open: open.map { open in { open(.usage) } })
            }
        case .usage:
            if let details = state.details {
                RunwareUsageBlock(
                    usage: details.usage, currency: details.balance.currency, isStale: state.detailsProblem != nil,
                    isCompact: isCompact, open: open.map { open in { open(.usage) } })
            }
        case .chart:
            RunwareChartBlock(
                activity: state.activity, problem: state.activityProblem, isFetching: state.isFetchingActivity,
                options: settings.chart, currency: state.details?.balance.currency ?? "USD", isCompact: isCompact,
                now: now, isExample: state.isExample, open: open.map { open in { open(.history) } })
        case .models:
            RunwareTopModelsBlock(
                activity: state.activity, problem: state.activityProblem, isFetching: state.isFetchingActivity,
                options: settings.models, currency: state.details?.balance.currency ?? "USD", isCompact: isCompact,
                open: open.map { open in { open(.models) } })
        }
    }

    /// Why there's nothing to show yet.
    @ViewBuilder
    private func message(problem: RunwareProblem?, isFetching: Bool, includesActivity: Bool) -> some View {
        if let problem {
            let retry = WidgetMessage.Action(title: "Try Again", isDisabled: isFetching) {
                state.refresh?(includesActivity || settings.showsActivity)
            }
            let openAccounts = WidgetMessage.Action(title: "Open Accounts", runsOnGlanceClick: true) {
                navigator.showAccounts(.runware)
            }
            WidgetMessage(
                title: problem.title, detail: problem.advice,
                systemImage: problem.needsKey ? "key" : "exclamationmark.triangle", layout: layout,
                action: problem.needsKey ? openAccounts : (state.refresh == nil ? nil : retry))
        } else {
            WidgetMessage(title: "Connecting to Runware…", detail: nil, systemImage: "hourglass", layout: layout)
        }
    }
}

/// The balance alone, for minimal columns and bars, with everything else in its tooltip.
private struct RunwareGlance: View {
    let details: RunwareAccountDetails
    let problem: RunwareProblem?
    let layout: WidgetLayout
    let now: Date
    let isExample: Bool
    let open: (() -> Void)?

    var body: some View {
        let content = Group {
            if layout == .bar {
                HStack(spacing: 5) {
                    Image(systemName: "creditcard.fill").foregroundStyle(.secondary)
                    figure
                    if problem != nil { RunwareStaleDot() }
                }
            } else {
                VStack(spacing: 2) {
                    figure.minimumScaleFactor(0.6)
                    if problem != nil { RunwareStaleDot() }
                }
            }
        }
        if let open {
            content.opens(open).help(tooltip + "\nClick for usage, history and models.")
        } else {
            content.help(tooltip)
        }
    }

    private var figure: some View {
        let balance = details.balance
        return Text(RunwareFormat.money(balance.amount, currency: balance.currency, abbreviated: true))
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(balance.amount < 0 ? Color.red : .primary)
            .opacity(problem == nil ? 1 : 0.6)
            .contentTransition(.numericText())
            .animation(Motion.gentle, value: balance.amount)
            .accessibilityLabel(balance.accessibilityText)
    }

    /// `Runware · Acme Corporation: $2,450.75 (+ $120.00 free)`, today's usage, and how fresh it is.
    private var tooltip: String {
        guard !isExample else { return "An example of a Runware balance, not yours" }
        let balance = details.balance
        var first = "Runware"
        if let name = details.organizationName { first += " · \(name)" }
        first += ": \(RunwareFormat.money(balance.amount, currency: balance.currency))"
        if let free = balance.freeBalance, free > 0 {
            first += " (+ \(RunwareFormat.money(free, currency: balance.currency)) free)"
        }
        var lines = [first]
        if let today = details.usage.today {
            let parts = [
                today.spend.map { RunwareFormat.money($0, currency: balance.currency) },
                today.requests.map(RunwareFormat.requests),
            ].compactMap(\.self)
            if !parts.isEmpty { lines.append("Today: " + parts.joined(separator: " · ")) }
        }
        lines.append("Updated \(UsageFormat.age(of: details.fetchedAt, now: now))")
        if let problem { lines.append("\(problem.title). \(problem.advice)") }
        return lines.joined(separator: "\n")
    }
}

/// Marks a value that's older than it should be: the last fetch failed.
struct RunwareStaleDot: View {
    var body: some View {
        Circle().fill(Color.orange).frame(width: 4, height: 4).accessibilityHidden(true)
    }
}

// MARK: - Previews

extension RunwareAccountDetails {
    /// What previews show, marked as an example. Not anyone's money.
    static func example(at now: Date) -> RunwareAccountDetails {
        RunwareAccountDetails(
            organizationName: "Example Studio",
            balance: RunwareBalance(amount: Decimal(string: "245.75")!, freeBalance: 12, currency: "USD"),
            usage: RunwareRollingUsage(
                today: RunwareUsageTotal(spend: Decimal(string: "3.58")!, requests: 185),
                last7Days: RunwareUsageTotal(spend: Decimal(string: "41.22")!, requests: 2140),
                last30Days: RunwareUsageTotal(spend: Decimal(string: "168.59")!, requests: 8756),
                total: RunwareUsageTotal(spend: Decimal(string: "892.05")!, requests: 45_318)),
            apiKeys: [
                RunwareAPIKeySummary(
                    name: "Production", requests: 40_120, createdAt: now.addingTimeInterval(-200 * 86_400),
                    lastUsedAt: now.addingTimeInterval(-90)),
                RunwareAPIKeySummary(
                    name: "Staging", isEnabled: false, requests: 5198, createdAt: now.addingTimeInterval(-90 * 86_400),
                    lastUsedAt: now.addingTimeInterval(-6 * 86_400)),
            ],
            fetchedAt: now.addingTimeInterval(-120))
    }
}

extension RunwareActivity {
    /// What previews show, marked as an example.
    static func example(at now: Date) -> RunwareActivity {
        let window = RunwareActivity.window(endingAt: now)
        let amounts = ["4.20", "6.85", "3.10", "8.40", "5.55", "7.25", "2.95"]
        var rows: [Row] = []
        var day = window.lowerBound
        var offset = 0
        while day <= window.upperBound {
            // Every ninth day reported nothing.
            if offset % 9 != 4 {
                let spend = Decimal(string: amounts[offset % amounts.count])!
                rows.append(Row(day: day, requests: 120 + (offset * 37) % 260, spend: spend))
            }
            day = day.adding(days: 1)
            offset += 1
        }
        let models = [
            ModelRow(air: "runware:101@1", name: "FLUX.1 Dev", requests: 4210, spend: Decimal(string: "88.40")!),
            ModelRow(
                air: "civitai:305149@392545", name: "Realistic XL", requests: 2980, spend: Decimal(string: "51.30")!),
            ModelRow(air: "runware:100@1", name: "FLUX.1 Schnell", requests: 1566, spend: Decimal(string: "28.89")!),
            ModelRow(
                air: "rundiffusion:130@100", name: "Juggernaut Pro", requests: 410, spend: Decimal(string: "9.15")!),
        ]
        return RunwareActivity(window: window, days: rows, models: models, fetchedAt: now.addingTimeInterval(-600))
    }
}
