import Foundation
import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let aiUsage = WidgetMetadata(
        title: "AI Usage",
        systemImage: "gauge.with.dots.needle.67percent",
        tint: .indigo,
        summary:
            "Codex, Claude Code and Cursor in one card: each one's limit closest to running out, and when it resets."
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
    var summary: String {
        guard !providers.isEmpty else { return "No agents chosen" }
        return "\(providers.map(\.shortTitle).joined(separator: ", ")) · \(reading.title)"
    }
}

// MARK: - Settings

/// Which agents to show and how, plus each one's source: the same opt-ins and setup as their own widgets, kept
/// separately for this one, so it works without them.
struct AIUsageSettingsEditor: View {
    @Binding var settings: AIUsageSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(AIUsageProvider.allCases) { provider in
                Toggle(isOn: included(provider)) {
                    Label {
                        Text(provider.title)
                    } icon: {
                        ProviderMark(provider: provider, size: 16)
                    }
                }
                // One agent at least: an empty card would only say so.
                .disabled(settings.providers == [provider])
            }
            caption(
                "Each agent's limit closest to running out, as that agent reports it. Agents measure different "
                    + "things over different windows, so nothing is added up across them.")
        }
        VStack(alignment: .leading, spacing: 8) {
            Picker("Limits show", selection: $settings.reading) {
                ForEach(UsageReading.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            caption(
                settings.reading == .used
                    ? "Meters fill as you use each agent, and their tick moves with the window's time: a meter that "
                        + "passes its tick runs out before the reset."
                    : "Like Codex's /status. Meters drain as you use each agent, and their tick drains with the "
                        + "window's time: a meter that falls short of its tick runs out before the reset."
            )
        }
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show other limits", isOn: $settings.showsOtherLimits)
            caption("Each agent's other windows or pools next to its main one, in the regular and compact sizes.")
        }
        ForEach(settings.providers) { provider in
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(provider.title).font(.headline)
                } icon: {
                    ProviderMark(provider: provider, size: 18)
                }
                source(of: provider)
            }
        }
    }

    @ViewBuilder
    private func source(of provider: AIUsageProvider) -> some View {
        switch provider {
        case .codex:
            CodexSourceStatus()
        case .claudeCode:
            AnthropicRefreshSettings(
                isOn: $settings.refreshesClaudeFromAnthropic, minutes: $settings.claudeRefreshMinutes)
            DisclosureGroup("Live limits from the status line") {
                StatusLineSetup().padding(.top, 6)
            }
        case .cursor:
            CursorFetchSettings(isOn: $settings.refreshesCursor, minutes: $settings.cursorRefreshMinutes)
        }
    }

    private func included(_ provider: AIUsageProvider) -> Binding<Bool> {
        Binding {
            settings.includes(provider)
        } set: {
            settings.set(provider, included: $0)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Widget

/// Reads the shared Codex, Claude Code and Cursor services (never its own copies) for the agents it shows, moving
/// on with the clock, or frozen in catalogs.
struct AIUsageWidgetView: View {
    let settings: AIUsageSettings
    let layout: WidgetLayout
    @Environment(CodexService.self) private var codex
    @Environment(ClaudeCodeService.self) private var claude
    @Environment(CursorService.self) private var cursor
    @Environment(\.frozenDate) private var frozenDate

    var body: some View {
        if let frozenDate {
            AIUsageView(summaries: summaries(at: frozenDate), settings: settings, layout: layout, now: frozenDate)
        } else {
            // Countdowns, the time tick, windows resetting and data ageing all move on with the clock.
            TimelineView(.everyMinute) { context in
                AIUsageView(
                    summaries: summaries(at: context.date), settings: settings, layout: layout, now: context.date)
            }
        }
    }

    /// Only the shown agents' services are read, so only their changes redraw the card.
    private func summaries(at now: Date) -> [AIUsageSummary] {
        settings.providers.map { provider in
            switch provider {
            case .codex:
                .codex(codex.state, plan: codex.state.plan.flatMap(CodexFormat.planTitle), now: now)
            case .claudeCode:
                .claudeCode(
                    usage: claude.usage, plan: claude.plan, hasLoaded: claude.hasLoaded,
                    anthropicProblem: claude.anthropicProblem, now: now)
            case .cursor:
                .cursor(
                    isConnected: settings.refreshesCursor, usage: cursor.usage, problem: cursor.problem,
                    isStale: cursor.isStale(at: now), now: now)
            }
        }
    }
}

/// One row per agent, each led by its limit closest to running out: its name and window, a meter with the
/// window's time tick, and when it resets, with the agent's other limits small beside it. Minimal and bar layouts
/// keep a mark, a number and a reset per agent. Percentages are never added up or compared across agents: each
/// row reads in its own windows, all of them as used or all as left.
struct AIUsageView: View {
    let summaries: [AIUsageSummary]
    let settings: AIUsageSettings
    let layout: WidgetLayout
    let now: Date

    private var reading: UsageReading { settings.reading }

    var body: some View {
        if summaries.isEmpty {
            if layout.isGlanceable {
                Image(systemName: "gauge.with.dots.needle.0percent")
                    .foregroundStyle(.secondary)
                    .help("No agents chosen")
            } else {
                Text("Choose agents in this widget's settings.").font(.callout).foregroundStyle(.secondary)
            }
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
            ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                if index > 0 {
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).padding(.vertical, 9)
                }
                regularRow(summary)
            }
        }
    }

    private func regularRow(_ summary: AIUsageSummary) -> some View {
        let lead = summary.status == .limits ? summary.lead(at: now) : nil
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 6) {
                ProviderMark(provider: summary.provider, size: 16)
                // Shortens, then drops the window's name, then the age, before the agent's name gives way.
                ViewThatFits(in: .horizontal) {
                    regularTitle(summary, window: lead?.title, showsAge: true)
                    regularTitle(summary, window: lead?.shortTitle, showsAge: true)
                    regularTitle(summary, window: lead?.shortTitle, showsAge: false)
                    regularTitle(summary, window: nil, showsAge: false)
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
        .row(summary, spokenValue: spokenValue(summary), help: help(summary))
    }

    /// `Codex  5-hour  ⏲ 2h ago`
    private func regularTitle(_ summary: AIUsageSummary, window: String?, showsAge: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(summary.provider.title).font(.system(size: 12, weight: .semibold))
            if let window {
                Text(window).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            freshnessBadge(summary, showsAged: true, showsAge: showsAge).font(.system(size: 9.5))
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
            ForEach(summaries) { summary in
                compactRow(summary)
            }
        }
    }

    private func compactRow(_ summary: AIUsageSummary) -> some View {
        let lead = summary.status == .limits ? summary.lead(at: now) : nil
        return VStack(alignment: .leading, spacing: 4) {
            // Drops the reading, then shortens and finally drops the agent's name, as the card narrows. The mark
            // always stays.
            ViewThatFits(in: .horizontal) {
                compactHeader(summary, lead: lead, title: summary.provider.title, suffix: true)
                compactHeader(summary, lead: lead, title: summary.provider.title, suffix: false)
                compactHeader(summary, lead: lead, title: summary.provider.shortTitle, suffix: false)
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
        .row(summary, spokenValue: spokenValue(summary), help: help(summary))
    }

    private func compactHeader(
        _ summary: AIUsageSummary, lead: AIUsageLimit?, title: String?, suffix: Bool
    ) -> some View {
        HStack(spacing: 5) {
            ProviderMark(provider: summary.provider, size: 14)
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

    /// A small "used" or "left" above one stack of agents: a mark, the number, a tiny meter and the reset each.
    private var minimal: some View {
        VStack(spacing: 8) {
            Text(reading.suffix.uppercased())
                .font(.system(size: 7.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            ForEach(summaries) { summary in
                minimalRow(summary)
            }
        }
    }

    private func minimalRow(_ summary: AIUsageSummary) -> some View {
        let lead = summary.status == .limits ? summary.lead(at: now) : nil
        return VStack(spacing: 3) {
            HStack(spacing: 3) {
                ProviderMark(provider: summary.provider, size: 13)
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
        .row(summary, spokenValue: spokenValue(summary), help: help(summary))
    }

    private var bar: some View {
        HStack(spacing: 9) {
            ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                if index > 0 {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.5, height: 18)
                }
                barItem(summary)
            }
        }
    }

    private func barItem(_ summary: AIUsageSummary) -> some View {
        let lead = summary.status == .limits ? summary.lead(at: now) : nil
        return HStack(spacing: 5) {
            ProviderMark(provider: summary.provider, size: 16)
                .opacity(lead == nil ? 0.6 : 1)
            if let lead {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        glancePercent(lead, summary: summary, size: 12.5)
                        if !lead.hasReset(at: now) {
                            Text(reading.suffix).font(.system(size: 8.5)).foregroundStyle(.secondary)
                        }
                    }
                    glanceReset(lead, summary: summary, size: 8.5)
                }
            } else {
                statusSymbol(summary).font(.system(size: 11))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .row(summary, spokenValue: spokenValue(summary), help: help(summary))
    }

    // MARK: Numbers and meters

    private var warningColor: Color { .usage(percent: 75) }
    private var criticalColor: Color { .usage(percent: 100) }

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
                    .foregroundStyle(limit.isUsedUp ? criticalColor : .primary)
                if suffix {
                    Text(reading.suffix).font(.system(size: max(9, size * 0.6))).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .animation(Motion.gentle, value: limit.window.usedPercent)
        }
    }

    /// The number alone, `–` once reset.
    private func glancePercent(_ limit: AIUsageLimit, summary: AIUsageSummary, size: CGFloat) -> some View {
        let hasReset = limit.hasReset(at: now)
        return Text(hasReset ? "–" : "\(Int(limit.percent(reading).rounded()))%")
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.7)
            .foregroundStyle(
                hasReset
                    ? AnyShapeStyle(.secondary)
                    : limit.isUsedUp || isBlocked(summary) ? AnyShapeStyle(criticalColor) : AnyShapeStyle(.primary)
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
                        isWarning ? warningColor : summary.freshness == .stale ? warningColor.opacity(0.8) : .secondary)
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
                            .foregroundStyle(limit.isUsedUp ? criticalColor : .primary)
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
                .foregroundStyle(criticalColor)
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
                    .foregroundStyle(criticalColor)
            case .runsOut(let date)?:
                let text =
                    switch length {
                    case .full: "Runs out \(moment(date))" + (resetSuffix(lead).map { " · \($0)" } ?? "")
                    case .short: "Runs out \(moment(date))"
                    case .tiny: "Runs out"
                    }
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(TightLabelStyle())
                    .foregroundStyle(warningColor)
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
                if showsAge { Text(CodexFormat.age(of: capturedAt, now: now)) }
            } icon: {
                Image(systemName: isStale ? "clock.badge.exclamationmark" : "clock")
            }
            .labelStyle(TightLabelStyle())
            .foregroundStyle(isStale ? AnyShapeStyle(warningColor) : AnyShapeStyle(.tertiary))
        }
    }

    @ViewBuilder
    private func statusSymbol(_ summary: AIUsageSummary) -> some View {
        switch summary.status {
        case .limits: EmptyView()
        case .loading: Image(systemName: "hourglass").foregroundStyle(.secondary)
        case .setup: Image(systemName: "gearshape").foregroundStyle(.secondary)
        case .noLimits: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(warningColor)
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
    private func spokenValue(_ summary: AIUsageSummary) -> String {
        guard summary.status == .limits else {
            return [statusTitle(summary), statusDetail(summary)].compactMap(\.self).joined(separator: ". ")
        }
        let ordered = [summary.lead(at: now)].compactMap(\.self) + summary.others(at: now)
        var parts = ordered.map { limit in
            var part = "\(limit.title) limit, "
            if limit.hasReset(at: now) {
                part += "reset, new usage not reported yet"
            } else {
                part += "\(Int(limit.percent(reading).rounded())) percent \(reading.suffix)"
                if let resetsAt = limit.window.resetsAt {
                    part += ", resets in \(CodexFormat.spokenDuration(until: resetsAt, now: now))"
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
            parts.append("As of \(CodexFormat.age(of: capturedAt, now: now))")
        }
        return parts.joined(separator: ". ")
    }

    private func help(_ summary: AIUsageSummary) -> String {
        var lines = [[summary.provider.title, summary.plan].compactMap(\.self).joined(separator: " · ")]
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
            lines.append("From \(source) · \(CodexFormat.age(of: capturedAt, now: now))")
        }
        if summary.provider == .cursor, summary.status == .limits {
            lines.append("For the whole account: the editor, the CLI and cloud agents share these pools.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Dates

    private func moment(_ date: Date) -> String { CodexFormat.moment(date, now: now) }

    /// `14:20` today, `Oct 28` on another day.
    private func day(_ date: Date) -> String {
        Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Bundled provider artwork, with appearance variants selected by the asset catalog.
private struct ProviderMark: View {
    let provider: AIUsageProvider
    let size: CGFloat

    var body: some View {
        Image(assetName, bundle: BrandLogos.bundle)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var assetName: String {
        switch provider {
        case .codex: "AIUsageCodex"
        case .claudeCode: "AIUsageClaude"
        case .cursor: "AIUsageCursor"
        }
    }
}

extension View {
    /// One agent as one VoiceOver element, named after it, with its numbers as the value and the details as a
    /// tooltip.
    fileprivate func row(_ summary: AIUsageSummary, spokenValue: String, help: String) -> some View {
        contentShape(Rectangle())
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.provider.title)
            .accessibilityValue(spokenValue)
    }
}
