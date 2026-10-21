import SidelightCore
import SwiftUI

/// The balance, free credits beside it, and how fresh it is. A click opens usage in details.
struct RunwareBalanceBlock: View {
    let details: RunwareAccountDetails
    let problem: RunwareProblem?
    let isFetching: Bool
    let options: RunwareBalanceOptions
    let isCompact: Bool
    let now: Date
    let isExample: Bool
    let refresh: (() -> Void)?
    let open: (() -> Void)?

    private var balance: RunwareBalance { details.balance }
    private var free: Decimal? {
        guard options.showsFreeCredits, let free = balance.freeBalance, free > 0 else { return nil }
        return free
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 2 : 6) {
            if isCompact {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    figure(size: 18)
                    Spacer(minLength: 2)
                    if let free {
                        Text("+ \(RunwareFormat.money(free, currency: balance.currency)) free")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                figure(size: 26)
                if let free {
                    Text("+ \(RunwareFormat.money(free, currency: balance.currency)) free")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 2) {
                    Text(updated)
                        .font(.system(size: 10))
                        .foregroundStyle(problem == nil ? Color.secondary : .orange)
                        .lineLimit(1)
                    if let refresh {
                        OpenRouterRefreshButton(isFetching: isFetching, help: "Fetch from Runware now", action: refresh)
                    }
                }
                .help(problem.map { "\($0.title). \($0.advice)" } ?? "")
            }
        }
        .modifier(RunwareOpens(open: open, help: "See usage, history and models"))
    }

    /// `Runware · Acme Corporation · USD`, or the block's title.
    private var label: String {
        if let title = options.title { return "\(title) · \(balance.currency)" }
        if isExample { return "Example balance · \(balance.currency)" }
        return ["Runware", details.organizationName, balance.currency].compactMap(\.self).joined(separator: " · ")
    }

    private func figure(size: CGFloat) -> some View {
        Text(RunwareFormat.money(balance.amount, currency: balance.currency))
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(balance.amount < 0 ? Color.red : .primary)
            .opacity(problem == nil ? 1 : 0.6)
            .contentTransition(.numericText())
            .animation(Motion.gentle, value: balance.amount)
            .accessibilityLabel(balance.accessibilityText)
    }

    /// `Updated 2m ago`, or why it's older than it should be.
    private var updated: String {
        guard !isExample else { return "An example: the panel shows your balance" }
        let age = UsageFormat.age(of: details.fetchedAt, now: now)
        guard let problem else { return "Updated \(age)" }
        return "\(problem.title) · \(age)"
    }
}

/// Today, 7 days and 30 days: spend over requests.
struct RunwareUsageBlock: View {
    let usage: RunwareRollingUsage
    let currency: String
    let isStale: Bool
    let isCompact: Bool
    let open: (() -> Void)?

    var body: some View {
        Group {
            if isCompact {
                Text(compactLine)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    column("Today", usage.today)
                    column("7 days", usage.last7Days)
                    column("30 days", usage.last30Days)
                }
            }
        }
        .opacity(isStale ? 0.6 : 1)
        .modifier(RunwareOpens(open: open, help: "See usage in detail"))
        .help(
            "Requests, not images: one request can return several results. Sidelight's own reads may count too.")
    }

    /// `Today $35.80 · 1,850 req`
    private var compactLine: String {
        let spend = usage.today?.spend.map { RunwareFormat.money($0, currency: currency) } ?? "—"
        let requests = usage.today?.requests.map { "\($0.formatted()) req" } ?? "— req"
        return "Today \(spend) · \(requests)"
    }

    private func column(_ title: String, _ total: RunwareUsageTotal?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(total?.spend.map { RunwareFormat.money($0, currency: currency) } ?? "—")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(total?.requests.map { "\($0.formatted()) req" } ?? "—")
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One bar per UTC day: spend or requests.
struct RunwareChartBlock: View {
    let activity: RunwareActivity?
    let problem: RunwareProblem?
    let isFetching: Bool
    let options: RunwareChartOptions
    let currency: String
    let isCompact: Bool
    let now: Date
    let isExample: Bool
    let open: (() -> Void)?

    var body: some View {
        if let activity {
            let days = activity.days(last: options.days)
            let isStale = problem != nil || activity.isBehind(at: now)
            VStack(alignment: .leading, spacing: 4) {
                RunwareBars(
                    days: days, metric: options.metric, currency: currency, partialDay: activity.window.upperBound,
                    height: isCompact ? 18 : 26
                )
                .opacity(isStale ? 0.55 : 1)
                if !isCompact {
                    Text(caption(days))
                        .font(.system(size: 9.5))
                        .foregroundStyle(isStale ? Color.orange : .secondary)
                        .lineLimit(1)
                }
            }
            .modifier(RunwareOpens(open: open, help: "See every day"))
            .help(help(days))
        } else {
            RunwareNote(
                text: problem.map { "Activity unavailable · \($0.title)" } ?? "Loading activity…",
                systemImage: problem == nil ? "hourglass" : "chart.bar.xaxis", isCompact: isCompact)
        }
    }

    /// `$412.25 · last 7 days (UTC)`
    private func caption(_ days: [RunwareDay]) -> String {
        let total =
            switch options.metric {
            case .spend: RunwareFormat.money(RunwareActivity.spend(of: days), currency: currency)
            case .requests: RunwareFormat.requests(RunwareActivity.requests(of: days))
            }
        let span = "\(total) · last \(days.count) days (UTC)"
        if isExample { return "Example · \(span)" }
        if let problem { return "\(problem.title) · \(span)" }
        return span
    }

    private func help(_ days: [RunwareDay]) -> String {
        guard !isExample else { return "An example of usage by UTC day, not yours" }
        var lines = ["\(options.metric.title) by UTC day. Today's bar is so far, and outlined."]
        if let problem { lines.append("\(problem.title). \(problem.advice)") }
        return lines.joined(separator: "\n")
    }
}

/// The bars of a chart, with each day's value on hover. A day with nothing reported gets a hairline, never a bar of
/// zero; the day still going is outlined, as it's partial.
struct RunwareBars: View {
    let days: [RunwareDay]
    let metric: RunwareChartMetric
    let currency: String
    /// The day still going, if it's among `days`.
    let partialDay: UTCDay?
    let height: CGFloat

    var body: some View {
        let maximum = max(days.compactMap(value).max() ?? 0, 0)
        let latestCompleted = days.last { $0.day != partialDay }?.day
        HStack(alignment: .bottom, spacing: days.count > 14 ? 1 : 2) {
            ForEach(days) { day in
                bar(day, isLatest: day.day == latestCompleted, maximum: maximum)
                    .help(help(day))
            }
        }
        .frame(height: height, alignment: .bottom)
        .animation(Motion.gentle, value: days)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title) over \(days.count) UTC days")
    }

    private func value(_ day: RunwareDay) -> Double? {
        switch metric {
        case .spend: day.spend?.approximateDouble
        case .requests: day.requests.map(Double.init)
        }
    }

    @ViewBuilder
    private func bar(_ day: RunwareDay, isLatest: Bool, maximum: Double) -> some View {
        if let value = value(day) {
            let fraction = maximum > 0 ? value / maximum : 0
            let shape = RoundedRectangle(cornerRadius: 1.5)
            if day.day == partialDay {
                shape
                    .fill(Color.accentColor.opacity(0.2))
                    .overlay(
                        shape.strokeBorder(
                            Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: max(3, height * fraction))
            } else {
                shape
                    .fill(isLatest ? Color.accentColor : Color.primary.opacity(0.28))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(2, height * fraction))
            }
        } else {
            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(maxWidth: .infinity)
                .frame(height: 1)
        }
    }

    private func help(_ day: RunwareDay) -> String {
        let date = RunwareFormat.shortDay(day.day) + (day.day == partialDay ? " so far" : "") + " (UTC)"
        guard day.isReported else { return "\(date): Nothing reported" }
        let parts = [
            day.spend.map { RunwareFormat.amount($0, currency: currency) }, day.requests.map(RunwareFormat.requests),
        ].compactMap(\.self)
        return "\(date): " + parts.joined(separator: " · ")
    }
}

/// The models that spent most over 30 days.
struct RunwareTopModelsBlock: View {
    let activity: RunwareActivity?
    let problem: RunwareProblem?
    let isFetching: Bool
    let options: RunwareModelsOptions
    let currency: String
    let isCompact: Bool
    let open: (() -> Void)?

    var body: some View {
        if let activity {
            let rows = Array(activity.models.prefix(isCompact ? min(options.rowCount, 3) : options.rowCount))
            let top = rows.compactMap { $0.spend?.approximateDouble }.max() ?? 0
            VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
                if !isCompact {
                    Text("TOP MODELS · 30 DAYS")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                }
                if rows.isEmpty {
                    Text("No models used")
                        .font(.system(size: isCompact ? 10 : 11))
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { model in
                    RunwareModelUsageRow(
                        model: model, currency: currency, share: share(model, of: top), isCompact: isCompact)
                }
                if !isCompact { footer }
            }
            .opacity(problem == nil ? 1 : 0.6)
            // The full block opens from its footer.
            .modifier(RunwareOpens(open: isCompact ? open : nil, help: "Browse models"))
        } else {
            RunwareNote(
                text: problem.map { "Models unavailable · \($0.title)" } ?? "Loading models…",
                systemImage: problem == nil ? "hourglass" : "square.stack.3d.up.slash", isCompact: isCompact)
        }
    }

    private func share(_ model: RunwareModelUsage, of top: Double) -> Double {
        guard top > 0, let spend = model.spend?.approximateDouble else { return 0 }
        return spend / top
    }

    private var footer: some View {
        Button {
            open?()
        } label: {
            HStack(spacing: 3) {
                Text("Browse models")
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(open == nil)
        .hoverHighlight(isEnabled: open != nil, vertical: 1)
        .help(open == nil ? "Opens from the panel" : "Search Runware's models, in place of the panel")
    }
}

/// A model's usage: its name, a thin bar for its share, and its spend. Right-click copies its AIR.
struct RunwareModelUsageRow: View {
    let model: RunwareModelUsage
    let currency: String
    /// Its spend against the top model's, 0 to 1.
    let share: Double
    let isCompact: Bool
    var showsAIR = false
    var showsRequests = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.displayName)
                    .font(.system(size: isCompact ? 11 : 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if showsRequests, let requests = model.requests {
                    Text("\(requests.formatted()) req")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(model.spend.map { RunwareFormat.amount($0, currency: currency) } ?? "—")
                    .font(.system(size: isCompact ? 10.5 : 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if showsAIR, model.name != nil {
                Text(model.air)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !isCompact {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: max(2, proxy.size.width * share))
                }
                .frame(height: 2)
            }
        }
        .contentShape(.rect)
        .contextMenu {
            Button("Copy AIR", systemImage: "doc.on.doc") { SessionHost.copy(model.air) }
        }
        .help("\(model.displayName)\n\(model.air)")
        .accessibilityElement(children: .combine)
    }
}

/// A short line in a block's place: loading, or why it can't show.
struct RunwareNote: View {
    let text: String
    let systemImage: String
    let isCompact: Bool

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: isCompact ? 9.5 : 10))
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

/// A click on the block opens details, where there's a panel to open it from.
private struct RunwareOpens: ViewModifier {
    let open: (() -> Void)?
    let help: String

    func body(content: Content) -> some View {
        if let open {
            content.opens(open).help(help)
        } else {
            content
        }
    }
}
