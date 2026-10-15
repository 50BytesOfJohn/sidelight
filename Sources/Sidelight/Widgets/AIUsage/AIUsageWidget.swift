import Foundation
import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let aiUsage = WidgetMetadata(
        title: "AI Usage",
        systemImage: "gauge.with.dots.needle.67percent",
        tint: .indigo,
        summary: "Codex, Claude and Cursor limits together",
        details: "Each agent's limit closest to running out, or a meter for each of its limits, as that agent "
            + "reports them, and when they reset. Agents measure different things over different windows, so "
            + "Sidelight doesn't add them up. Built from blocks: one per agent, or one per account to watch several "
            + "Claude accounts, each with its own look."
    )
}

extension AIUsageProvider {
    /// The provider's own widget supplies its display name.
    var kind: WidgetKind {
        switch self {
        case .codex: .codex
        case .claudeCode: .claudeCode
        case .cursor: .cursor
        }
    }

    var title: String { kind.metadata.title }

    /// The same agent, as the sessions widgets know it.
    var agent: AgentProvider {
        switch self {
        case .codex: .codex
        case .claudeCode: .claudeCode
        case .cursor: .cursor
        }
    }

    /// For narrow cards.
    var shortTitle: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude"
        case .cursor: "Cursor"
        }
    }
}

extension AIUsageSettings {
    /// The Widgets window's one-line description: the shown blocks by name, and how limits read.
    var summary: String {
        let names = blocks.shownBlocks.map { options($0).label ?? $0.provider.shortTitle }
        guard !names.isEmpty else { return "No agents shown" }
        return "\(names.joined(separator: ", ")) · \(reading.title)"
    }
}

// MARK: - Widget

/// One block as the card draws it: its agent's numbers, under the name the block goes by.
struct AIUsageRow: Identifiable {
    let block: AIUsageBlock
    let summary: AIUsageSummary
    /// The block's own label, if it has one.
    let label: String?
    let variant: AIUsageBlockVariant

    var id: AIUsageBlock { block }
    var provider: AIUsageProvider { block.provider }
    /// The label, or the agent's name.
    var title: String { label ?? provider.title }
    /// The label, or the agent's short name, for narrow cards.
    var shortTitle: String { label ?? provider.shortTitle }
    /// `Work, Claude Code`: the label and the agent, for VoiceOver and tooltips.
    var fullTitle: String { label.map { "\($0), \(provider.title)" } ?? provider.title }
}

/// Reads the shared Codex, Claude Code and Cursor services (never its own copies) for the blocks it shows, moving
/// on with the clock, or frozen in catalogs.
struct AIUsageWidgetView: View {
    let settings: AIUsageSettings
    let layout: WidgetLayout
    @Environment(CodexService.self) private var codex
    @Environment(ClaudeCodeService.self) private var claude
    @Environment(CursorService.self) private var cursor
    @Environment(AccountStore.self) private var accounts

    var body: some View {
        // Countdowns, the time tick, windows resetting and data ageing all move on with the clock.
        WidgetClock { now in
            AIUsageView(rows: rows(at: now), settings: settings, layout: layout, now: now)
        }
    }

    /// Only the shown blocks' services are read, so only their changes redraw the card.
    private func rows(at now: Date) -> [AIUsageRow] {
        settings.blocks.shownBlocks.map { block in
            let options = settings.options(block)
            return AIUsageRow(
                block: block, summary: summary(of: block, options: options, at: now), label: options.label,
                variant: options.variant)
        }
    }

    private func summary(of block: AIUsageBlock, options: AIUsageBlockOptions, at now: Date) -> AIUsageSummary {
        switch block.provider {
        case .codex:
            .codex(codex.state, plan: codex.state.plan.flatMap(UsageFormat.planTitle), now: now)
        case .claudeCode:
            claudeSummary(account: options.account, at: now)
        case .cursor:
            .cursor(
                isConnected: settings.refreshesCursor, usage: cursor.usage, problem: cursor.problem,
                isStale: cursor.isStale(at: now), now: now)
        }
    }

    /// A Claude block's account; a reference to one that's gone says so rather than showing another.
    private func claudeSummary(account: AccountID?, at now: Date) -> AIUsageSummary {
        guard case .account(let id) = accounts.resolve(account, at: .claudeCode) else {
            return AIUsageSummary(
                provider: .claudeCode,
                status: .setup(title: "Claude account not found", detail: "Choose one in this widget's builder."))
        }
        let account = claude.account(id)
        return .claudeCode(
            usage: account?.usage, plan: account?.plan, hasLoaded: account?.hasLoaded ?? false,
            anthropicProblem: account?.anthropicProblem, now: now)
    }
}

/// One row per block, each led by its agent's limit closest to running out: its name and window, a meter with the
/// window's time tick, and when it resets, with the agent's other limits small beside it. Minimal and bar layouts
/// keep a mark, a number and a reset per block. A block showing each limit draws a meter per limit instead, always
/// in the same order. Percentages are never added up or compared across agents: each
/// row reads in its own windows, all of them as used or all as left.
struct AIUsageView: View {
    let rows: [AIUsageRow]
    let settings: AIUsageSettings
    let layout: WidgetLayout
    let now: Date

    private var reading: UsageReading { settings.reading }

    var body: some View {
        if rows.isEmpty {
            WidgetMessage(
                title: "No agents shown", detail: "Add them in this widget's builder.",
                systemImage: "gauge.with.dots.needle.0percent", layout: layout, trimsCompact: false)
        } else {
            switch layout {
            case .regular: regular
            case .compact: compact
            case .minimal: minimal
            case .bar: bar
            }
        }
    }

    // MARK: Layouts

    private var regular: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    HairlineDivider().padding(.vertical, 9)
                }
                if showsEachLimit(row) { eachLimitRegularRow(row) } else { regularRow(row) }
            }
        }
        .animation(Motion.layout, value: rows.map(\.id))
    }

    private func regularRow(_ row: AIUsageRow) -> some View {
        let summary = row.summary
        let lead = summary.status == .limits ? summary.lead(at: now) : nil
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 6) {
                ProviderLogo(provider: row.provider.agent, size: 16)
                // Shortens, then drops the window's name, then the age, before the block's name gives way.
                ViewThatFits(in: .horizontal) {
                    regularTitle(row, window: lead?.title, showsAge: true)
                    regularTitle(row, window: lead?.shortTitle, showsAge: true)
                    regularTitle(row, window: lead?.shortTitle, showsAge: false)
                    regularTitle(row, window: nil, showsAge: false)
                }
                Spacer(minLength: 4)
                if let lead {
                    percentLabel(lead, summary: summary, size: 17, suffix: true)
                } else {
                    statusSymbol(summary).font(.system(size: 12))
                }
            }
            if let lead {
                meter(lead, summary: summary, height: 5)
                ViewThatFits(in: .horizontal) {
                    regularDetail(summary, lead: lead, length: .full, others: settings.showsOtherLimits)
                    regularDetail(summary, lead: lead, length: .short, others: settings.showsOtherLimits)
                    regularDetail(summary, lead: lead, length: .short, others: false)
                }
                .font(.system(size: 10))
                .lineLimit(1)
            } else {
                message(summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .row(row, spokenValue: spokenValue(summary, variant: row.variant), help: help(row))
    }

    /// `Codex  5-hour  ⏲ 2h ago`
    private func regularTitle(_ row: AIUsageRow, window: String?, showsAge: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(row.title).font(.system(size: 12, weight: .semibold))
            if let window {
                Text(window).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            freshnessBadge(row.summary, showsAged: true, showsAge: showsAge).font(.system(size: 9.5))
        }
        .lineLimit(1)
    }

    /// `Resets in 2h 14m      wk 61%`
    private func regularDetail(
        _ summary: AIUsageSummary, lead: AIUsageLimit, length: DetailLength, others: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            leadDetail(summary, lead: lead, length: length)
            Spacer(minLength: 0)
            if others {
                otherLimits(summary)
            }
        }
    }

    private var compact: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row in
                if showsEachLimit(row) { eachLimitCompactRow(row) } else { compactRow(row) }
            }
        }
        .animation(Motion.layout, value: rows.map(\.id))
    }

    private func compactRow(_ row: AIUsageRow) -> some View {
        let summary = row.summary
        let lead = summary.status == .limits ? summary.lead(at: now) : nil
        return VStack(alignment: .leading, spacing: 4) {
            // Drops the reading, then shortens and finally drops the block's name, as the card narrows. The mark
            // always stays.
            ViewThatFits(in: .horizontal) {
                compactHeader(summary, lead: lead, title: row.title, suffix: true)
                compactHeader(summary, lead: lead, title: row.title, suffix: false)
                compactHeader(summary, lead: lead, title: row.shortTitle, suffix: false)
                compactHeader(summary, lead: lead, title: nil, suffix: false)
            }
            if let lead {
                meter(lead, summary: summary, height: 4)
                ViewThatFits(in: .horizontal) {
                    compactDetail(summary, lead: lead, length: .short, others: settings.showsOtherLimits)
                    compactDetail(summary, lead: lead, length: .tiny, others: settings.showsOtherLimits)
                    compactDetail(summary, lead: lead, length: .tiny, others: false)
                }
                .font(.system(size: 9.5))
                .lineLimit(1)
            } else {
                Text(statusTitle(summary))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .row(row, spokenValue: spokenValue(summary, variant: row.variant), help: help(row))
    }

    private func compactHeader(
        _ summary: AIUsageSummary, lead: AIUsageLimit?, title: String?, suffix: Bool
    ) -> some View {
        HStack(spacing: 5) {
            ProviderLogo(provider: summary.provider.agent, size: 14)
            if let title {
                Text(title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 3)
            if let lead {
                percentLabel(lead, summary: summary, size: 13, suffix: suffix)
            } else {
                statusSymbol(summary).font(.system(size: 10))
            }
        }
    }

    /// `5h · in 2h 14m      wk 61%`, with the window's name in front since the header has no room for it.
    private func compactDetail(
        _ summary: AIUsageSummary, lead: AIUsageLimit, length: DetailLength, others: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(lead.shortTitle).fontWeight(.semibold).foregroundStyle(.secondary)
                leadDetail(summary, lead: lead, length: length)
            }
            if summary.freshness == .stale {
                freshnessBadge(summary, showsAged: false, showsAge: length != .tiny)
            }
            Spacer(minLength: 0)
            if others {
                otherLimits(summary)
            }
        }
    }

    /// A small "used" or "left" above one stack of blocks: a mark, the number, a tiny meter and the reset each, and
    /// the block's label when it has one.
    private var minimal: some View {
        VStack(spacing: 8) {
            Text(reading.suffix.uppercased())
                .font(.system(size: 7.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            ForEach(rows) { row in
                if showsEachLimit(row) { eachLimitMinimalRow(row) } else { minimalRow(row) }
            }
        }
    }

    private func minimalRow(_ row: AIUsageRow) -> some View {
        let summary = row.summary
        let lead = summary.status == .limits ? summary.lead(at: now) : nil
        return VStack(spacing: 3) {
            if let label = row.label {
                glanceLabel(label, size: 8)
            }
            HStack(spacing: 3) {
                ProviderLogo(provider: row.provider.agent, size: 13)
                    .opacity(lead == nil ? 0.6 : 1)
                if let lead {
                    glancePercent(lead, summary: summary, size: 11.5)
                } else {
                    statusSymbol(summary).font(.system(size: 10))
                }
            }
            if let lead {
                tinyMeter(lead, summary: summary).frame(width: 40)
                glanceReset(lead, summary: summary, size: 8.5)
            }
        }
        .lineLimit(1)
        .row(row, spokenValue: spokenValue(summary, variant: row.variant), help: help(row))
    }

    private var bar: some View {
        HStack(spacing: 9) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.5, height: 18)
                }
                if showsEachLimit(row) { eachLimitBarItem(row) } else { barItem(row) }
            }
        }
    }

    private func barItem(_ row: AIUsageRow) -> some View {
        let summary = row.summary
        let lead = summary.status == .limits ? summary.lead(at: now) : nil
        return HStack(spacing: 5) {
            ProviderLogo(provider: row.provider.agent, size: 16)
                .opacity(lead == nil ? 0.6 : 1)
            if let lead {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        glancePercent(lead, summary: summary, size: 12.5)
                        if !lead.hasReset(at: now) {
                            Text(reading.suffix).font(.system(size: 8.5)).foregroundStyle(.secondary)
                        }
                    }
                    // The label takes the reset's place: telling the blocks apart matters more in a bar.
                    if let label = row.label {
                        glanceLabel(label, size: 8.5)
                    } else {
                        glanceReset(lead, summary: summary, size: 8.5)
                    }
                }
            } else {
                if let label = row.label {
                    glanceLabel(label, size: 9)
                }
                statusSymbol(summary).font(.system(size: 11))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .row(row, spokenValue: spokenValue(summary, variant: row.variant), help: help(row))
    }

    /// A block's label in the smallest sizes, kept short.
    private func glanceLabel(_ label: String, size: CGFloat) -> some View {
        Text(label)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.secondary)
            .truncationMode(.tail)
            .frame(maxWidth: 64)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Each limit

    /// Whether `row` draws a meter per limit. Without limits to draw, it says why the same way in either look.
    private func showsEachLimit(_ row: AIUsageRow) -> Bool {
        row.variant == .eachLimit && row.summary.status == .limits
    }

    /// The agent's name over a meter per limit, each in its place: `5h [meter] 34%  in 2h 14m`.
    private func eachLimitRegularRow(_ row: AIUsageRow) -> some View {
        let summary = row.summary
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                ProviderLogo(provider: row.provider.agent, size: 16)
                // Drops the reading first, as `compactHeader` does, then the age.
                ViewThatFits(in: .horizontal) {
                    eachLimitTitle(row, showsAge: true, suffix: true)
                    eachLimitTitle(row, showsAge: true, suffix: false)
                    eachLimitTitle(row, showsAge: false, suffix: false)
                }
            }
            ViewThatFits(in: .horizontal) {
                limitGrid(summary, meterHeight: 5, countdown: .short, size: 10)
                limitGrid(summary, meterHeight: 5, countdown: .tiny, size: 10)
            }
            noticeLine(summary).font(.system(size: 10))
        }
        .row(row, spokenValue: spokenValue(summary, variant: row.variant), help: help(row))
    }

    /// The agent's name and how fresh the numbers are, with `used` or `left` at the end once for every limit.
    private func eachLimitTitle(_ row: AIUsageRow, showsAge: Bool, suffix: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(row.title).font(.system(size: 12, weight: .semibold))
            freshnessBadge(row.summary, showsAged: true, showsAge: showsAge).font(.system(size: 9.5))
            Spacer(minLength: 3)
            if suffix {
                Text(reading.suffix).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    private func eachLimitCompactRow(_ row: AIUsageRow) -> some View {
        let summary = row.summary
        return VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                eachLimitCompactHeader(summary, title: row.title, suffix: true)
                eachLimitCompactHeader(summary, title: row.title, suffix: false)
                eachLimitCompactHeader(summary, title: row.shortTitle, suffix: false)
                eachLimitCompactHeader(summary, title: nil, suffix: false)
            }
            // The countdowns give way first: the numbers are what a compact card is for.
            ViewThatFits(in: .horizontal) {
                limitGrid(summary, meterHeight: 4, countdown: .tiny, size: 9.5)
                limitGrid(summary, meterHeight: 4, countdown: nil, size: 9.5)
            }
            noticeLine(summary).font(.system(size: 9.5))
        }
        .row(row, spokenValue: spokenValue(summary, variant: row.variant), help: help(row))
    }

    private func eachLimitCompactHeader(_ summary: AIUsageSummary, title: String?, suffix: Bool) -> some View {
        HStack(spacing: 5) {
            ProviderLogo(provider: summary.provider.agent, size: 14)
            if let title {
                Text(title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            }
            freshnessBadge(summary, showsAged: false, showsAge: false).font(.system(size: 9))
            Spacer(minLength: 3)
            if suffix {
                Text(reading.suffix).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    /// A row per limit: its short name, its meter, the number, and, with `countdown`, when it resets, in the warning
    /// color when it runs out early or is used up.
    private func limitGrid(
        _ summary: AIUsageSummary, meterHeight: CGFloat, countdown: DetailLength?, size: CGFloat
    ) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: meterHeight + 3) {
            ForEach(summary.shownLimits(.eachLimit, at: now)) { limit in
                GridRow(alignment: .center) {
                    Text(limit.shortTitle)
                        .font(.system(size: size, weight: .semibold))
                        .foregroundStyle(.secondary)
                    meter(limit, summary: summary, height: meterHeight)
                        .frame(minWidth: 28, maxWidth: .infinity)
                    glancePercent(limit, summary: summary, size: size + 1)
                        .gridColumnAlignment(.trailing)
                    if let countdown {
                        limitCountdown(limit, summary: summary, length: countdown)
                            .font(.system(size: size))
                    }
                }
            }
        }
        .lineLimit(1)
    }

    /// `in 2h 14m`, `Tue 06:00`, `awaiting update`; `in 2h`, `Tue`, `new` when `tiny`.
    private func limitCountdown(_ limit: AIUsageLimit, summary: AIUsageSummary, length: DetailLength) -> some View {
        let text = length == .tiny ? shortCountdown(limit) ?? "" : resetText(limit, short: true)
        let color: Color? =
            switch summary.warning(for: limit, at: now) {
            case .usedUp?: .usageCritical
            case .runsOut?: .usageWarning
            case nil: nil
            }
        return Text(text)
            .monospacedDigit()
            .foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .fixedSize()
    }

    /// What the meters alone don't say: Codex stopped, Cursor's on-demand usage, numbers that are out of date.
    @ViewBuilder
    private func noticeLine(_ summary: AIUsageSummary) -> some View {
        if let notice = summary.notice {
            let (symbol, color): (String, Color) =
                switch notice.severity {
                case .critical: ("hourglass", .usageCritical)
                case .warning: ("exclamationmark.triangle.fill", .usageWarning)
                case .info: ("info.circle", .secondary)
                }
            Label(notice.text, systemImage: symbol)
                .labelStyle(TightLabelStyle())
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// The mark, and the block's label when it has one, over each limit's name, number and tiny meter.
    private func eachLimitMinimalRow(_ row: AIUsageRow) -> some View {
        let summary = row.summary
        return VStack(spacing: 3) {
            if let label = row.label {
                glanceLabel(label, size: 8)
            }
            ProviderLogo(provider: row.provider.agent, size: 13)
            ForEach(summary.shownLimits(.eachLimit, at: now)) { limit in
                VStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(limit.shortTitle)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                        glancePercent(limit, summary: summary, size: 10.5)
                    }
                    tinyMeter(limit, summary: summary).frame(width: 40)
                }
            }
        }
        .lineLimit(1)
        .row(row, spokenValue: spokenValue(summary, variant: row.variant), help: help(row))
    }

    /// The mark, the label when there is one, and `5h 34%` over `wk 61%`; a single limit is one line.
    private func eachLimitBarItem(_ row: AIUsageRow) -> some View {
        let summary = row.summary
        let limits = summary.shownLimits(.eachLimit, at: now)
        let size: CGFloat = limits.count > 1 ? 10 : 12.5
        return HStack(spacing: 5) {
            ProviderLogo(provider: row.provider.agent, size: 16)
            if let label = row.label {
                glanceLabel(label, size: 9)
            }
            VStack(alignment: .leading, spacing: -1) {
                ForEach(limits) { limit in
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(limit.shortTitle)
                            .font(.system(size: size - 2, weight: .semibold))
                            .foregroundStyle(.secondary)
                        glancePercent(limit, summary: summary, size: size)
                        // Once for the block: every limit reads the same way.
                        if limit.id == limits.first?.id {
                            Text(reading.suffix).font(.system(size: max(9, size * 0.6))).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
        .row(row, spokenValue: spokenValue(summary, variant: row.variant), help: help(row))
    }

    // MARK: Numbers and meters

    /// `34% used`, or `Reset` once the window has reset since the numbers were read.
    @ViewBuilder
    private func percentLabel(_ limit: AIUsageLimit, summary: AIUsageSummary, size: CGFloat, suffix: Bool) -> some View
    {
        if limit.hasReset(at: now) {
            Text("Reset").font(.system(size: size * 0.75, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(limit.percent(reading).rounded()))%")
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: limit.percent(reading)))
                    .foregroundStyle(limit.isUsedUp ? Color.usageCritical : .primary)
                if suffix {
                    Text(reading.suffix).font(.system(size: max(9, size * 0.6))).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .animation(Motion.gentle, value: limit.window.usedPercent)
        }
    }

    /// The number alone, `–` once reset, in the warning color when the limit is forecast to run out early.
    private func glancePercent(_ limit: AIUsageLimit, summary: AIUsageSummary, size: CGFloat) -> some View {
        let hasReset = limit.hasReset(at: now)
        return Text(hasReset ? "–" : "\(Int(limit.percent(reading).rounded()))%")
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.7)
            .foregroundStyle(
                hasReset
                    ? AnyShapeStyle(.secondary)
                    : limit.isUsedUp || isBlocked(summary)
                        ? AnyShapeStyle(Color.usageCritical)
                        : summary.warning(for: limit, at: now) != nil
                            ? AnyShapeStyle(Color.usageWarning) : AnyShapeStyle(.primary)
            )
            .opacity(summary.freshness == .stale ? 0.6 : 1)
    }

    /// `5h in 2h`, `wk Tue`, `API 18d`; `5h new` once reset.
    private func glanceReset(_ limit: AIUsageLimit, summary: AIUsageSummary, size: CGFloat) -> some View {
        let isWarning = summary.warning(for: limit, at: now) != nil || isBlocked(summary)
        return HStack(spacing: 2) {
            Text(limit.shortTitle).font(.system(size: size - 0.5, weight: .semibold)).foregroundStyle(.secondary)
            if let countdown = shortCountdown(limit) {
                Text(countdown)
                    .font(.system(size: size, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(
                        isWarning
                            ? Color.usageWarning
                            : summary.freshness == .stale ? Color.usageWarning.opacity(0.8) : .secondary)
            }
        }
    }

    /// The meter for one limit: a segment per hour, day or week, with the time tick. Once the window has reset, its
    /// new usage isn't known, so it's an empty, dimmed track either way: never a full "all left" one.
    private func meter(_ limit: AIUsageLimit, summary: AIUsageSummary, height: CGFloat) -> some View {
        let hasReset = limit.hasReset(at: now)
        return SegmentedMeter(
            percent: hasReset ? 0 : limit.window.usedPercent,
            segments: limit.segments,
            elapsedFraction: hasReset ? nil : limit.window.elapsedFraction(at: now),
            height: height,
            spacing: 2,
            showsRemaining: !hasReset && reading == .remaining
        )
        .opacity(hasReset || summary.freshness == .stale ? 0.45 : 1)
        .accessibilityHidden(true)
    }

    private func tinyMeter(_ limit: AIUsageLimit, summary: AIUsageSummary) -> some View {
        let hasReset = limit.hasReset(at: now)
        return SegmentedMeter(
            percent: hasReset ? 0 : limit.window.usedPercent,
            segments: limit.segments,
            height: 3,
            spacing: 1,
            showsRemaining: !hasReset && reading == .remaining
        )
        .opacity(hasReset || summary.freshness == .stale ? 0.45 : 1)
        .accessibilityHidden(true)
    }

    /// `wk 61%  Auto 12%`: the agent's other limits, at a glance.
    private func otherLimits(_ summary: AIUsageSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            ForEach(summary.others(at: now)) { limit in
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(limit.shortTitle).foregroundStyle(.secondary)
                    if limit.hasReset(at: now) {
                        Text("reset").foregroundStyle(.secondary)
                    } else {
                        Text("\(Int(limit.percent(reading).rounded()))%")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(limit.isUsedUp ? Color.usageCritical : .primary)
                    }
                }
                .opacity(summary.freshness == .stale ? 0.6 : 1)
            }
        }
        .fixedSize()
    }

    // MARK: Status

    private func isBlocked(_ summary: AIUsageSummary) -> Bool { summary.notice?.severity == .critical }

    /// How much room there is for a limit's status line.
    private enum DetailLength {
        /// `At this pace, runs out Thu 08:10`, `Resets in 2h 14m`.
        case full
        /// `Runs out Thu 08:10`, `in 2h 14m`.
        case short
        /// `Runs out`, `in 2h`.
        case tiny
    }

    /// What to say under the lead's meter, most urgent first: the agent stopped, the limit's used up or runs out
    /// early, or when it resets.
    @ViewBuilder
    private func leadDetail(_ summary: AIUsageSummary, lead: AIUsageLimit, length: DetailLength) -> some View {
        if let notice = summary.notice, notice.severity == .critical {
            let text = length == .full ? notice.text : length == .short ? "Limit reached" : "Stopped"
            Label(text, systemImage: "hourglass")
                .labelStyle(TightLabelStyle())
                .foregroundStyle(Color.usageCritical)
        } else {
            switch summary.warning(for: lead, at: now) {
            case .usedUp?:
                let text =
                    switch length {
                    case .full where summary.notice?.severity == .info: "Used up · on-demand from here"
                    case .full: resetSuffix(lead).map { "Used up · \($0)" } ?? "Used up until it resets"
                    case .short, .tiny: "Used up"
                    }
                Label(text, systemImage: "hourglass")
                    .labelStyle(TightLabelStyle())
                    .foregroundStyle(Color.usageCritical)
            case .runsOut(let date)?:
                let text =
                    switch length {
                    case .full: "Runs out \(moment(date))" + (resetSuffix(lead).map { " · \($0)" } ?? "")
                    case .short: "Runs out \(moment(date))"
                    case .tiny: "Runs out"
                    }
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(TightLabelStyle())
                    .foregroundStyle(Color.usageWarning)
            case nil:
                let text = length == .tiny ? shortCountdown(lead) ?? "" : resetText(lead, short: length == .short)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }

    /// `resets in 36m`, `resets Sat 10:09`, after a warning that would otherwise hide when the limit comes back.
    private func resetSuffix(_ limit: AIUsageLimit) -> String? {
        guard let resetsAt = limit.window.resetsAt, resetsAt > now else { return nil }
        let text = resetText(limit, short: false)
        return text.prefix(1).lowercased() + text.dropFirst()
    }

    /// `Resets in 2h 14m`, `Resets Tue 06:00`, `Resets Oct 28`, or `Reset 14:20, awaiting update` once it has
    /// passed. `short` drops the verb.
    private func resetText(_ limit: AIUsageLimit, short: Bool) -> String {
        guard let resetsAt = limit.window.resetsAt else {
            return limit.startsWithNextMessage ? (short ? "not started" : "Starts with your next message") : ""
        }
        if resetsAt <= now {
            if short { return "awaiting update" }
            return limit.isBillingCycle ? "New cycle, awaiting update" : "Reset \(moment(resetsAt)), awaiting update"
        }
        if resetsAt.timeIntervalSince(now) < 86_400 {
            let countdown = Formatting.countdown(to: resetsAt, now: now)
            return short ? "in \(countdown)" : "Resets in \(countdown)"
        }
        let moment = limit.isBillingCycle ? day(resetsAt) : moment(resetsAt)
        return short ? moment : "Resets \(moment)"
    }

    /// `in 2h`, `in 14m`, `Tue`, or `18d` for a billing cycle; `new` once reset. "in" keeps a countdown apart from
    /// a window's name (`5h`) right before it.
    private func shortCountdown(_ limit: AIUsageLimit) -> String? {
        guard let resetsAt = limit.window.resetsAt else { return limit.startsWithNextMessage ? "idle" : nil }
        if resetsAt <= now { return "new" }
        if limit.isBillingCycle { return Formatting.countdownLeadingUnit(to: resetsAt, now: now) }
        let countdown = Formatting.shortCountdown(to: resetsAt, now: now)
        return resetsAt.timeIntervalSince(now) < 86_400 ? "in \(countdown)" : countdown
    }

    /// How old the numbers are, when it matters: always once stale (in the warning color), and with `showsAged`
    /// also when they're merely not current.
    @ViewBuilder
    private func freshnessBadge(_ summary: AIUsageSummary, showsAged: Bool, showsAge: Bool = true) -> some View {
        if let capturedAt = summary.capturedAt, summary.status == .limits,
            summary.freshness == .stale || (showsAged && summary.freshness == .aged)
        {
            let isStale = summary.freshness == .stale
            Label {
                if showsAge { Text(UsageFormat.age(of: capturedAt, now: now)) }
            } icon: {
                Image(systemName: isStale ? "clock.badge.exclamationmark" : "clock")
            }
            .labelStyle(TightLabelStyle())
            .foregroundStyle(isStale ? AnyShapeStyle(Color.usageWarning) : AnyShapeStyle(.tertiary))
        }
    }

    @ViewBuilder
    private func statusSymbol(_ summary: AIUsageSummary) -> some View {
        switch summary.status {
        case .limits: EmptyView()
        case .loading: Image(systemName: "hourglass").foregroundStyle(.secondary)
        case .setup: Image(systemName: "gearshape").foregroundStyle(.secondary)
        case .noLimits: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(Color.usageWarning)
        }
    }

    private func statusTitle(_ summary: AIUsageSummary) -> String {
        switch summary.status {
        case .limits: ""
        case .loading(let title): title
        case .setup(let title, _), .noLimits(let title, _), .failed(let title, _): title
        }
    }

    private func statusDetail(_ summary: AIUsageSummary) -> String? {
        switch summary.status {
        case .limits, .loading: nil
        case .setup(_, let detail): detail
        case .noLimits(_, let detail), .failed(_, let detail): detail
        }
    }

    /// `Not connected. Turn on Fetch usage from Cursor in this widget's settings.`
    private func message(_ summary: AIUsageSummary) -> Text {
        let title = Text(statusTitle(summary)).fontWeight(.medium)
        guard let detail = statusDetail(summary) else { return title }
        return Text("\(title). \(detail)")
    }

    // MARK: Accessibility and tooltips

    /// `5-hour limit, 34 percent used, resets in 2 hours, 14 minutes. Weekly limit, 61 percent used. As of 2h ago.`
    /// Limits are read in the order the block draws them: the lead first, or each in its place.
    private func spokenValue(_ summary: AIUsageSummary, variant: AIUsageBlockVariant) -> String {
        guard summary.status == .limits else {
            return [statusTitle(summary), statusDetail(summary)].compactMap(\.self).joined(separator: ". ")
        }
        let ordered =
            switch variant {
            case .closestLimit: summary.shownLimits(.closestLimit, at: now) + summary.others(at: now)
            case .eachLimit: summary.shownLimits(.eachLimit, at: now)
            }
        var parts = ordered.map { limit in
            var part = "\(limit.title) limit, "
            if limit.hasReset(at: now) {
                part += "reset, new usage not reported yet"
            } else {
                part += "\(Int(limit.percent(reading).rounded())) percent \(reading.suffix)"
                if let resetsAt = limit.window.resetsAt {
                    part += ", resets in \(UsageFormat.spokenDuration(until: resetsAt, now: now))"
                }
            }
            switch summary.warning(for: limit, at: now) {
            case .usedUp?: part += ", used up"
            case .runsOut(let date)?: part += ", runs out \(moment(date)) at this pace"
            case nil: break
            }
            return part
        }
        if let notice = summary.notice { parts.append(notice.text) }
        if summary.freshness != .live, let capturedAt = summary.capturedAt {
            parts.append("As of \(UsageFormat.age(of: capturedAt, now: now))")
        }
        return parts.joined(separator: ". ")
    }

    private func help(_ row: AIUsageRow) -> String {
        let summary = row.summary
        var lines = [[row.label, summary.provider.title, summary.plan].compactMap(\.self).joined(separator: " · ")]
        if summary.status == .limits {
            for limit in summary.limits {
                let value =
                    limit.hasReset(at: now)
                    ? "reset, awaiting update" : "\(Int(limit.percent(reading).rounded()))% \(reading.suffix)"
                let reset = resetText(limit, short: false)
                lines.append(
                    "\(limit.title): \(value)" + (reset.isEmpty || limit.hasReset(at: now) ? "" : " · \(reset)"))
                if let explanation = limit.explanation { lines.append(explanation) }
            }
        } else {
            lines.append([statusTitle(summary), statusDetail(summary)].compactMap(\.self).joined(separator: ". "))
        }
        if let notice = summary.notice { lines.append(notice.text) }
        if let source = summary.source, let capturedAt = summary.capturedAt {
            lines.append("From \(source) · \(UsageFormat.age(of: capturedAt, now: now))")
        }
        if summary.provider == .cursor, summary.status == .limits {
            lines.append("For the whole account: the editor, the CLI and cloud agents share these pools.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Dates

    private func moment(_ date: Date) -> String { UsageFormat.moment(date, now: now) }

    private func day(_ date: Date) -> String { UsageFormat.day(date, now: now) }
}

extension View {
    /// One block as one VoiceOver element, named after its label and agent, with its numbers as the value and the
    /// details as a tooltip.
    fileprivate func row(_ row: AIUsageRow, spokenValue: String, help: String) -> some View {
        contentShape(Rectangle())
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.fullTitle)
            .accessibilityValue(spokenValue)
    }
}
