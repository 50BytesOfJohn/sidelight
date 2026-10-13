import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let openRouterCredits = WidgetMetadata(
        title: "OpenRouter Credits",
        systemImage: "creditcard.fill",
        tint: .indigo,
        summary: "Your OpenRouter account's balance, and what it spent each UTC day. Needs a management key.",
        isBeta: true,
        family: "OpenRouter"
    )
}

extension OpenRouterCreditsSettings {
    var summary: String {
        let refresh = refresh.minutes.map { "Every \($0) min" } ?? "Manual"
        guard chart.isShown else { return "\(refresh) · No chart" }
        let scope = chart.scope == .key ? "Key \(chart.keyName ?? "not chosen")" : "Account"
        return "\(refresh) · \(chart.days)-day chart · \(scope)"
    }
}

// MARK: - Widget

struct OpenRouterCreditsWidgetView: View {
    let settings: OpenRouterCreditsSettings
    let layout: WidgetLayout
    @Environment(OpenRouterService.self) private var service
    @Environment(\.isWidgetPreview) private var isPreview

    var body: some View {
        WidgetClock { now in
            content(now: now)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let balance = service.balance
        if isPreview {
            // The Widgets window and the builder show what the widget looks like, with an example marked as one: never
            // the account's money, and the key is never read for it.
            OpenRouterCreditsContent(
                balance: .example(at: now), problem: nil, isFetching: false,
                chart: settings.chart.isShown ? .example(at: now) : nil, settings: settings, layout: layout,
                now: now, isExample: true, refresh: nil)
        } else if let value = balance.value {
            // A key OpenRouter rejected isn't tried again until it's replaced: nothing to refresh until then.
            OpenRouterCreditsContent(
                balance: value, problem: balance.problem, isFetching: balance.isFetching, chart: chart(now: now),
                settings: settings, layout: layout, now: now, isExample: false,
                refresh: balance.problem?.needsKey == true
                    ? nil : { service.refreshAccount(scope: settings.chart.spendScope) })
        } else if let problem = balance.problem {
            let retry = WidgetMessage.Action(title: "Try Again", isDisabled: balance.isFetching) {
                service.refreshAccount(scope: settings.chart.spendScope)
            }
            WidgetMessage(
                title: problem == .noKey ? "Add an OpenRouter management key" : problem.title,
                detail: problem.advice,
                systemImage: problem.needsKey ? "key" : "exclamationmark.triangle",
                layout: layout,
                action: problem.needsKey ? nil : retry)
        } else if service.hasKey == false {
            WidgetMessage(
                title: "Add an OpenRouter management key", detail: OpenRouterProblem.noKey.advice,
                systemImage: "key", layout: layout)
        } else {
            WidgetMessage(title: "Connecting to OpenRouter…", detail: nil, systemImage: "hourglass", layout: layout)
        }
    }

    /// What the chart shows, when it's on.
    private func chart(now: Date) -> OpenRouterSpendChartState? {
        guard settings.chart.isShown else { return nil }
        guard let scope = settings.chart.spendScope else { return .chooseKey }
        guard let activity = service.activity(for: scope) else { return .loading }
        if let value = activity.value {
            let isStale = activity.problem != nil || value.isBehind(at: now)
            return .days(value, isStale: isStale, problem: activity.problem)
        }
        if let problem = activity.problem { return .failed(problem, isRetrying: activity.isFetching) }
        return .loading
    }
}

/// What the spending chart can show.
enum OpenRouterSpendChartState {
    /// Set to a key, but none chosen yet.
    case chooseKey
    case loading
    /// Never fetched successfully: no chart at all, never an empty one.
    case failed(OpenRouterProblem, isRetrying: Bool)
    /// What OpenRouter reported. Stale after a failed fetch, or once a day has ended since.
    case days(OpenRouterActivity, isStale: Bool, problem: OpenRouterProblem?)
}

/// The balance, how fresh it is, and the chart below it.
private struct OpenRouterCreditsContent: View {
    let balance: OpenRouterBalance
    /// Why the last fetch failed, while showing an older balance.
    let problem: OpenRouterProblem?
    let isFetching: Bool
    let chart: OpenRouterSpendChartState?
    let settings: OpenRouterCreditsSettings
    let layout: WidgetLayout
    let now: Date
    /// An example in a preview, not the account's money: it says so.
    let isExample: Bool
    /// `nil` in previews, which never fetch.
    let refresh: (() -> Void)?

    private var isStale: Bool { problem != nil }
    private var isNegative: Bool { balance.remaining < 0 }

    var body: some View {
        switch layout {
        case .regular, .compact:
            let isCompact = layout == .compact
            VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
                if !isCompact {
                    Text((isExample ? "Example balance · USD" : "Account balance · USD").uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                }
                figure(size: isCompact ? 18 : 26)
                if !isCompact {
                    HStack(spacing: 2) {
                        Text(updated)
                            .font(.system(size: 10))
                            .foregroundStyle(isStale ? Color.orange : .secondary)
                            .lineLimit(1)
                        if let refresh {
                            OpenRouterRefreshButton(
                                isFetching: isFetching, help: "Fetch the balance now", action: refresh)
                        }
                    }
                    if settings.chart.isShown && settings.chart.scope == .key {
                        Text("Balance is account-wide")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let chart {
                    OpenRouterSpendChart(
                        state: chart, settings: settings.chart, isCompact: isCompact, now: now, isExample: isExample,
                        retry: refresh
                    )
                    .padding(.top, isCompact ? 2 : 6)
                }
            }
        case .minimal:
            VStack(spacing: 2) {
                figure(size: 12.5)
                    .minimumScaleFactor(0.6)
                if isStale { staleDot }
            }
            .help(tooltip)
        case .bar:
            HStack(spacing: 5) {
                Image(systemName: "creditcard.fill")
                    .foregroundStyle(.secondary)
                figure(size: 12.5)
                if isStale { staleDot }
            }
            .help(tooltip)
        }
    }

    private func figure(size: CGFloat) -> some View {
        Text(OpenRouterFormat.dollars(balance.remaining))
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(isNegative ? Color.red : .primary)
            .opacity(isStale ? 0.6 : 1)
            .contentTransition(.numericText())
            .animation(Motion.gentle, value: balance.remaining)
            .accessibilityLabel(
                "\(isExample ? "Example balance" : "Account balance") \(OpenRouterFormat.dollars(balance.remaining))")
    }

    private var staleDot: some View {
        Circle().fill(Color.orange).frame(width: 4, height: 4).accessibilityHidden(true)
    }

    /// `Updated 4m ago`, or why it's older than it should be.
    private var updated: String {
        guard !isExample else { return "An example: the panel shows your balance" }
        let age = UsageFormat.age(of: balance.fetchedAt, now: now)
        guard let problem else { return "Updated \(age)" }
        return "\(problem.title) · \(age)"
    }

    private var tooltip: String {
        guard !isExample else { return "An example of the OpenRouter account balance, not yours" }
        var lines = ["OpenRouter account balance: \(OpenRouterFormat.dollars(balance.remaining))"]
        lines.append("Updated \(UsageFormat.age(of: balance.fetchedAt, now: now))")
        if let problem { lines.append("\(problem.title). \(problem.advice)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Chart

/// One bar per completed UTC day, the most recent highlighted. A day OpenRouter reported nothing for gets a hairline,
/// never a bar of zero; a chart that never loaded says so, rather than drawing an empty one.
struct OpenRouterSpendChart: View {
    let state: OpenRouterSpendChartState
    let settings: OpenRouterSpendChartSettings
    let isCompact: Bool
    let now: Date
    /// An example in a preview, not the account's spending.
    let isExample: Bool
    let retry: (() -> Void)?

    var body: some View {
        switch state {
        case .chooseKey:
            note("Choose a key for the chart in the widget's settings.", systemImage: "key")
        case .loading:
            note("Loading spending…", systemImage: "hourglass")
        case .failed(let problem, let isRetrying):
            VStack(alignment: .leading, spacing: 3) {
                note(failureTitle(problem), systemImage: "chart.bar.xaxis")
                if !isCompact, let retry, !problem.needsKey, problem != .keyNotFound {
                    Button(isRetrying ? "Trying…" : "Try Again", action: retry)
                        .controlSize(.mini)
                        .disabled(isRetrying)
                }
            }
            .help("\(problem.title). \(problem.advice)")
        case .days(let activity, let isStale, let problem):
            chart(activity, isStale: isStale, problem: problem)
        }
    }

    private func chart(_ activity: OpenRouterActivity, isStale: Bool, problem: OpenRouterProblem?) -> some View {
        let days = activity.days(settings.days)
        let total = OpenRouterActivity.total(of: days)
        let byok = OpenRouterActivity.byokTotal(of: days)
        return VStack(alignment: .leading, spacing: 4) {
            SpendBars(days: days, height: isCompact ? 18 : 26)
                .opacity(isStale ? 0.55 : 1)
            if !isCompact {
                HStack(spacing: 4) {
                    Text(caption(total: total))
                        .lineLimit(1)
                    if isStale {
                        Text("· as of \(OpenRouterFormat.day(activity.lastCompletedDay))")
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                if activity.key?.isDisabled == true {
                    Text("This key is disabled")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .help(help(total: total, byok: byok, activity: activity, problem: problem))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Spending over the last \(days.count) completed UTC days: \(OpenRouterFormat.dollars(total))")
    }

    /// `$1.55 · last 7 UTC days`, or `Key "dev-laptop" · $1.55 · last 7 UTC days`.
    private func caption(total: Decimal) -> String {
        let span = "\(OpenRouterFormat.dollars(total)) · last \(settings.days) UTC days"
        guard !isExample else { return "Example · \(span)" }
        guard settings.scope == .key else { return span }
        return "Key “\(settings.keyName ?? "chosen key")” · \(span)"
    }

    private func help(
        total: Decimal, byok: Decimal?, activity: OpenRouterActivity, problem: OpenRouterProblem?
    ) -> String {
        guard !isExample else { return "An example of spending by UTC day, not yours" }
        var lines = [
            "Charged to your credits over the last \(settings.days) completed UTC days: "
                + OpenRouterFormat.dollars(total)
        ]
        if let byok, byok > 0 {
            lines.append("+ \(OpenRouterFormat.dollars(byok)) through your own provider keys (BYOK), not from credits")
        }
        lines.append("Through \(OpenRouterFormat.longDay(activity.lastCompletedDay)) (UTC). Today isn't over yet.")
        if let problem { lines.append("\(problem.title). \(problem.advice)") }
        return lines.joined(separator: "\n")
    }

    private func failureTitle(_ problem: OpenRouterProblem) -> String {
        switch problem {
        case .keyNotFound: "Key “\(settings.keyName ?? "chosen key")” not found"
        default: "Spending unavailable"
        }
    }

    private func note(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: isCompact ? 9.5 : 10))
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

/// The bars themselves, with each day's amount on hover.
private struct SpendBars: View {
    let days: [OpenRouterSpendDay]
    let height: CGFloat

    var body: some View {
        let maximum = max(days.compactMap { $0.usage?.approximateDouble }.max() ?? 0, 0)
        HStack(alignment: .bottom, spacing: days.count > 14 ? 1 : 2) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                bar(day, isLatest: index == days.count - 1, maximum: maximum)
                    .help(help(day))
            }
        }
        .frame(height: height, alignment: .bottom)
        .animation(Motion.gentle, value: days)
    }

    @ViewBuilder
    private func bar(_ day: OpenRouterSpendDay, isLatest: Bool, maximum: Double) -> some View {
        if let usage = day.usage {
            let fraction = maximum > 0 ? usage.approximateDouble / maximum : 0
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isLatest ? Color.accentColor : Color.primary.opacity(0.28))
                .frame(maxWidth: .infinity)
                .frame(height: max(2, height * fraction))
        } else {
            // Nothing reported: a baseline tick, not a bar.
            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(maxWidth: .infinity)
                .frame(height: 1)
        }
    }

    private func help(_ day: OpenRouterSpendDay) -> String {
        let date = OpenRouterFormat.day(day.day)
        guard let usage = day.usage else { return "\(date) (UTC): No activity reported" }
        var text = "\(date) (UTC): \(OpenRouterFormat.dayAmount(usage))"
        if let byok = day.byokUsage, byok > 0 {
            text += "\n+ \(OpenRouterFormat.dayAmount(byok)) BYOK (not from your credits)"
        }
        return text
    }
}

// MARK: - Previews

extension OpenRouterBalance {
    /// What previews show, marked as an example. Not anyone's money.
    static func example(at now: Date) -> OpenRouterBalance {
        OpenRouterBalance(totalCredits: 100, totalUsage: Decimal(string: "25.75")!, fetchedAt: now)
    }
}

extension OpenRouterSpendChartState {
    /// What previews show, marked as an example.
    static func example(at now: Date) -> OpenRouterSpendChartState {
        let amounts = ["0.42", "0.18", "0.61", "0.05", "0.33", "0.27", "0.9"]
        let lastDay = UTCDay(now).adding(days: -1)
        let rows = (0..<OpenRouterActivity.reportedDays).compactMap { offset -> (UTCDay, Decimal, Decimal?)? in
            // Every fifth day reported nothing.
            guard offset % 5 != 3 else { return nil }
            let amount = Decimal(string: amounts[offset % amounts.count])!
            return (lastDay.adding(days: -offset), amount, nil)
        }
        return .days(
            OpenRouterActivity(rows: rows.map { (day: $0.0, usage: $0.1, byok: $0.2) }, fetchedAt: now),
            isStale: false, problem: nil)
    }
}
