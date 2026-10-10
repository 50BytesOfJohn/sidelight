import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let codex = WidgetMetadata(
        title: "Codex",
        systemImage: "chart.pie",
        tint: .orange,
        summary: "Codex plan limits: what's left of the 5-hour and weekly windows, when they reset, and tokens per day."
    )
}

extension CodexSettings {
    var summary: String {
        let reading = limitReading == .remaining ? "What's left" : "What's used"
        return "\(reading) · \(showsWeeklyLimit ? "5-hour + weekly" : "5-hour only")"
    }
}

extension UsageReading {
    var title: String {
        switch self {
        case .remaining: "What's left"
        case .used: "What's used"
        }
    }

    /// After a percentage: `66% left`.
    var suffix: String {
        switch self {
        case .remaining: "left"
        case .used: "used"
        }
    }
}

// MARK: - Settings

struct CodexSettingsEditor: View {
    @Binding var settings: CodexSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Limits show", selection: $settings.limitReading) {
                ForEach(CodexSettings.LimitReading.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            caption(
                settings.limitReading == .remaining
                    ? "Like Codex's /status. Meters drain as you use Codex, and their tick drains with the window's "
                        + "time: a meter that falls short of its tick runs out before the reset."
                    : "Like the Claude Code and Cursor widgets. Meters fill as you use Codex, and their tick moves "
                        + "with the window's time: a meter that passes its tick runs out before the reset."
            )
        }
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show weekly limit", isOn: $settings.showsWeeklyLimit)
            caption("A plan with a single limit always shows it.")
        }
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show token history", isOn: $settings.showsTokenHistory)
            caption("Tokens per day over two weeks and in total in the regular layout, and today's in compact.")
        }
        Divider()
        CodexSourceStatus()
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Where Codex's numbers come from and how that's going, with a throttled refresh.
struct CodexSourceStatus: View {
    @Environment(CodexService.self) private var codex

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            status
            Text(
                "Reads your plan's usage through the Codex CLI (codex app-server), signed in as Codex is, with "
                    + "read-only requests. Without it, the limits come from Codex's session logs on this Mac and "
                    + "update when Codex runs."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var status: some View {
        let state = codex.state
        return TimelineView(.everyMinute) { context in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(statusColor(state, now: context.date))
                    .frame(width: 7, height: 7)
                Text(statusText(state, now: context.date))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Refresh", systemImage: "arrow.clockwise") { codex.refreshNow() }
                    .labelStyle(.iconOnly)
                    .disabled(state.source == .off)
                    .help("Ask Codex now")
            }
        }
    }

    private func statusColor(_ state: CodexState, now: Date) -> Color {
        if state.account.map({ !$0.hasPlanLimits }) == true || state.problem != nil { return .orange }
        if state.isLive(at: now) { return .green }
        return state.rateLimits != nil ? .yellow : .secondary
    }

    private func statusText(_ state: CodexState, now: Date) -> String {
        switch state.account {
        case .signedOut?: return "Codex isn't signed in. Run codex login."
        case .apiKey?: return "Codex is signed in with an API key, which has no plan limits."
        case .otherProvider?: return "Codex is set up for another provider, which has no ChatGPT plan limits."
        case .chatGPT?, nil: break
        }
        if let problem = state.problem { return "codex app-server: \(problem)" }
        let age = state.limitsCapturedAt.map { " · \(CodexFormat.age(of: $0, now: now))" } ?? ""
        return switch state.source {
        case .off: "Starts while a widget showing Codex is visible"
        case .starting where state.rateLimits != nil: "Reconnecting to codex app-server\(age)"
        case .starting: "Starting codex app-server…"
        case .appServer: "Live from codex app-server\(age)"
        case .rolloutFile: "From Codex's session logs\(age)"
        case .unavailable: "Codex not found. Install the Codex CLI, or use Codex once."
        }
    }
}

// MARK: - Widget

/// Draws the service's current state, moving on with the clock (or frozen, in catalogs).
struct CodexWidgetView: View {
    let settings: CodexSettings
    let layout: WidgetLayout
    @Environment(CodexService.self) private var codex
    @Environment(\.frozenDate) private var frozenDate

    var body: some View {
        if let frozenDate {
            CodexUsageView(state: codex.state, settings: settings, layout: layout, now: frozenDate)
        } else {
            // Countdowns, the time tick, windows resetting and data ageing all move on with the clock.
            TimelineView(.everyMinute) { context in
                CodexUsageView(state: codex.state, settings: settings, layout: layout, now: context.date)
            }
        }
    }
}

/// Codex's limits read like its own `/status`: what's left of each window, as a meter that drains (or fills, if
/// set to show what's used) with a tick for the window's time, and when it resets. The 5-hour and weekly limits
/// sit side by side at the same scale, since either can be the one that stops you; token history sits apart,
/// below, in neutral colors. Minimal and bar layouts lead with whichever limit runs out first.
///
/// Nothing is guessed: a window whose reset has passed shows as reset with its new usage unknown until Codex
/// reports it, and forecasts only appear while the numbers are live.
struct CodexUsageView: View {
    let state: CodexState
    let settings: CodexSettings
    let layout: WidgetLayout
    let now: Date

    private var limits: [CodexLimit] {
        state.rateLimits?.limits(includesLonger: settings.showsWeeklyLimit) ?? []
    }

    private var reading: CodexSettings.LimitReading { settings.limitReading }
    private var isLive: Bool { state.isLive(at: now) }

    var body: some View {
        if let message = blockingMessage {
            messageView(message)
        } else if !limits.isEmpty {
            switch layout {
            case .regular: regular
            case .compact: compact
            case .minimal: minimal
            case .bar: bar
            }
        } else if let today = todayTokens {
            historyOnly(today: today)
        } else {
            messageView(emptyMessage)
        }
    }

    // MARK: States

    private struct Message {
        var title: String
        var detail: String?
        var systemImage: String
    }

    /// States where there are no limits worth showing, whatever has been read before.
    private var blockingMessage: Message? {
        switch state.account {
        case .signedOut?:
            Message(
                title: "Not signed in to Codex", detail: "Run codex login to see your plan's limits.",
                systemImage: "person.crop.circle.badge.questionmark")
        case .apiKey?:
            Message(
                title: "Codex uses an API key", detail: "Plan limits apply when it's signed in with ChatGPT.",
                systemImage: "key")
        case .otherProvider?:
            Message(
                title: "No ChatGPT plan limits", detail: "Codex is set up for another provider.",
                systemImage: "server.rack")
        case .chatGPT?, nil:
            nil
        }
    }

    private var emptyMessage: Message {
        if state.rateLimits != nil {
            return Message(
                title: "No limits reported", detail: "Codex sent no usage windows for this plan.",
                systemImage: "gauge.with.dots.needle.0percent")
        }
        if let problem = state.problem {
            return Message(title: "Can't read Codex limits", detail: problem, systemImage: "exclamationmark.circle")
        }
        return switch state.source {
        case .unavailable:
            Message(
                title: "Codex not found", detail: "Install the Codex CLI and sign in, or use Codex once on this Mac.",
                systemImage: "terminal")
        case .off, .starting, .appServer, .rolloutFile:
            Message(title: "Reading Codex usage…", systemImage: "hourglass")
        }
    }

    @ViewBuilder
    private func messageView(_ message: Message) -> some View {
        if layout.isGlanceable {
            Image(systemName: message.systemImage)
                .foregroundStyle(.secondary)
                .help([message.title, message.detail].compactMap(\.self).joined(separator: ". "))
                .accessibilityLabel([message.title, message.detail].compactMap(\.self).joined(separator: ". "))
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(message.title).font(.callout)
                if let detail = message.detail {
                    Text(detail).font(.caption).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    /// Token usage without any limits, such as when only `account/usage/read` answered.
    @ViewBuilder
    private func historyOnly(today: Int64) -> some View {
        switch layout {
        case .regular:
            VStack(alignment: .leading, spacing: 10) {
                Text("No plan limits reported").font(.callout).foregroundStyle(.secondary)
                tokenHistory
                footer
            }
        case .compact:
            VStack(alignment: .leading, spacing: 4) {
                Text("No limits reported").font(.system(size: 10.5)).foregroundStyle(.secondary)
                todayLine(today)
            }
        case .minimal:
            VStack(spacing: 3) {
                Image(systemName: "chart.bar.xaxis").foregroundStyle(.secondary)
                Text(Formatting.compactCount(today)).font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .help("No plan limits reported. \(Formatting.compactCount(today)) tokens today.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("No plan limits reported. \(Formatting.compactCount(today)) tokens today.")
        case .bar:
            todayLine(today)
        }
    }

    // MARK: Layouts

    private var regular: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reason = blockedReason {
                blockedBanner(reason).font(.system(size: 11, weight: .medium))
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(limits) { limit in
                    regularLimit(limit, isAlone: limits.count == 1)
                }
            }
            if settings.showsTokenHistory, hasTokenHistory {
                tokenHistory
            }
            footer
        }
    }

    private func regularLimit(_ limit: CodexLimit, isAlone: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(limit.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                if isAlone {
                    Spacer(minLength: 4)
                    resetText(limit, short: false).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            largePercent(limit, size: isAlone ? 30 : 26)
            meter(limit, height: 6)
            if !isAlone {
                resetText(limit, short: false)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning = warning(for: limit) {
                warningLabel(warning).font(.system(size: 10.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(limit.title) limit")
        .accessibilityValue(spokenValue(limit))
    }

    private var compact: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let reason = blockedReason {
                blockedBanner(reason).font(.system(size: 10, weight: .medium))
            }
            ForEach(limits) { limit in
                VStack(alignment: .leading, spacing: 4) {
                    // Drops "left" first, then shortens the name, as the card narrows.
                    ViewThatFits(in: .horizontal) {
                        compactHeader(limit, title: limit.title, withSuffix: true)
                        compactHeader(limit, title: limit.title, withSuffix: false)
                        compactHeader(
                            limit, title: limit.shortTitle.isEmpty ? limit.title : limit.shortTitle, withSuffix: false)
                    }
                    meter(limit, height: 5, spacing: 2)
                    Group {
                        if let warning = warning(for: limit) {
                            warningLabel(warning)
                        } else {
                            ViewThatFits(in: .horizontal) {
                                resetText(limit, short: false)
                                resetText(limit, short: true)
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 9.5))
                    .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(limit.title) limit")
                .accessibilityValue(spokenValue(limit))
            }
            if settings.showsTokenHistory, let today = todayTokens {
                todayLine(today)
            }
            if let age = staleAge {
                Label(age, systemImage: "clock")
                    .labelStyle(TightLabelStyle())
                    .font(.system(size: 9.5))
                    .foregroundStyle(freshnessStyle)
                    .lineLimit(1)
                    .help(freshnessHelp)
            }
        }
    }

    private func compactHeader(_ limit: CodexLimit, title: String, withSuffix: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            percentText(limit, size: 13, withSuffix: withSuffix)
        }
        .lineLimit(1)
    }

    /// The limit that runs out first as a tick gauge with its percentage inside, which one it is and when it
    /// resets, and the other as a tiny meter.
    @ViewBuilder
    private var minimal: some View {
        if let lead = CodexLimit.tightest(limits, at: now) {
            VStack(spacing: 4) {
                TickGauge(
                    percent: lead.hasReset(at: now) ? 0 : lead.window.usedPercent,
                    elapsedFraction: lead.hasReset(at: now) ? nil : lead.window.elapsedFraction(at: now),
                    diameter: 40,
                    showsRemaining: !lead.hasReset(at: now) && reading == .remaining
                )
                .overlay {
                    Text(lead.hasReset(at: now) ? "–" : "\(Int(shownPercent(lead).rounded()))")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: 22)
                        .foregroundStyle(lead.isUsedUp || isBlocked ? Color.usage(percent: 100) : .primary)
                        .contentTransition(.numericText(value: shownPercent(lead)))
                        .animation(Motion.gentle, value: lead.window.usedPercent)
                }
                .opacity(isStale ? 0.55 : 1)
                VStack(spacing: 0) {
                    if !lead.shortTitle.isEmpty {
                        Text(lead.shortTitle).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    if let countdown = shortCountdown(lead) {
                        Text(countdown)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(warning(for: lead) != nil ? warningColor : .secondary)
                    }
                }
                .lineLimit(1)
                ForEach(limits.filter { $0.id != lead.id }) { other in
                    tinyMeter(other).frame(width: 34)
                }
            }
            .help(glanceHelp(lead: lead))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Codex limits")
            .accessibilityValue(glanceSpokenValue(lead: lead))
        }
    }

    private var bar: some View {
        HStack(spacing: 7) {
            if let lead = CodexLimit.tightest(limits, at: now) {
                TickGauge(
                    percent: lead.hasReset(at: now) ? 0 : lead.window.usedPercent,
                    elapsedFraction: lead.hasReset(at: now) ? nil : lead.window.elapsedFraction(at: now),
                    diameter: 22, ticks: 24, innerFraction: 0.5,
                    showsRemaining: !lead.hasReset(at: now) && reading == .remaining
                )
                .opacity(isStale ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 0) {
                    percentText(lead, size: 13, withSuffix: false)
                    if !lead.shortTitle.isEmpty {
                        Text("\(lead.shortTitle) \(reading.suffix)")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(limits.filter { $0.id != lead.id }) { other in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            percentText(other, size: 10.5, withSuffix: false)
                            Text(other.shortTitle).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        tinyMeter(other)
                    }
                    .fixedSize()
                }
                if let countdown = shortCountdown(lead) {
                    Text(countdown)
                        .font(.system(size: 10.5, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(warning(for: lead) != nil || isStale ? warningColor : .secondary)
                }
            }
        }
        .lineLimit(1)
        .help(CodexLimit.tightest(limits, at: now).map(glanceHelp(lead:)) ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex limits")
        .accessibilityValue(CodexLimit.tightest(limits, at: now).map(glanceSpokenValue(lead:)) ?? "")
    }

    // MARK: Limits

    private var warningColor: Color { .usage(percent: 75) }

    /// Codex has stopped ordinary usage, whatever the percentages say.
    private var isBlocked: Bool { state.isBlocked }

    /// Why Codex stopped, when a used-up limit on screen doesn't already say so.
    private var blockedReason: String? {
        guard isBlocked else { return nil }
        let isExplained = limits.contains { $0.isUsedUp && !$0.hasReset(at: now) }
        if isExplained, state.rateLimits?.reachedType.map({ $0 == "rate_limit_reached" }) ?? true { return nil }
        return switch state.rateLimits?.reachedType {
        case "workspace_owner_credits_depleted", "workspace_member_credits_depleted": "Workspace credits used up"
        case "workspace_owner_usage_limit_reached", "workspace_member_usage_limit_reached":
            "Workspace usage limit reached"
        default: "Usage limit reached"
        }
    }

    /// The reason, or just "Limit reached" where it doesn't fit.
    private func blockedBanner(_ reason: String) -> some View {
        ViewThatFits(in: .horizontal) {
            ForEach([reason, "Limit reached"], id: \.self) { text in
                Label(text, systemImage: "hourglass").labelStyle(TightLabelStyle()).lineLimit(1)
            }
        }
        .foregroundStyle(Color.usage(percent: 100))
        .help(reason)
    }

    private func shownPercent(_ limit: CodexLimit) -> Double {
        let used = min(max(limit.window.usedPercent, 0), 100)
        return reading == .remaining ? 100 - used : used
    }

    /// The meter for one limit: a segment per hour or day, with the time tick. Once the window has reset its new
    /// usage isn't known, so it's an empty, dimmed track either way: never a full "all left" one.
    private func meter(_ limit: CodexLimit, height: CGFloat, spacing: CGFloat = 2.5) -> some View {
        let hasReset = limit.hasReset(at: now)
        return SegmentedMeter(
            percent: hasReset ? 0 : limit.window.usedPercent,
            segments: limit.segments,
            elapsedFraction: hasReset ? nil : limit.window.elapsedFraction(at: now),
            height: height,
            spacing: spacing,
            showsRemaining: !hasReset && reading == .remaining
        )
        .opacity(hasReset || isStale ? 0.45 : 1)
    }

    private func tinyMeter(_ limit: CodexLimit) -> some View {
        let hasReset = limit.hasReset(at: now)
        return SegmentedMeter(
            percent: hasReset ? 0 : limit.window.usedPercent,
            segments: limit.segments,
            height: 2.5,
            spacing: 1,
            showsRemaining: !hasReset && reading == .remaining
        )
        .opacity(hasReset || isStale ? 0.45 : 1)
    }

    private func largePercent(_ limit: CodexLimit, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if limit.hasReset(at: now) {
                Text("Reset").font(.system(size: size * 0.62, weight: .semibold, design: .rounded))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(shownPercent(limit).rounded()))")
                        .font(.system(size: size, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: shownPercent(limit)))
                    Text("%").font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(limit.isUsedUp ? Color.usage(percent: 100) : .primary)
                Text(reading.suffix).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .animation(Motion.gentle, value: limit.window.usedPercent)
    }

    @ViewBuilder
    private func percentText(_ limit: CodexLimit, size: CGFloat, withSuffix: Bool) -> some View {
        if limit.hasReset(at: now) {
            Text("Reset").font(.system(size: size * 0.8, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(shownPercent(limit).rounded()))%")
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: shownPercent(limit)))
                    .foregroundStyle(limit.isUsedUp ? Color.usage(percent: 100) : .primary)
                if withSuffix {
                    Text(reading.suffix).font(.system(size: size * 0.75)).foregroundStyle(.secondary)
                }
            }
            .animation(Motion.gentle, value: limit.window.usedPercent)
        }
    }

    private enum Warning {
        case usedUp
        case runsOut(Date)
    }

    /// What needs attention about a limit: it's used up, or (while live) it runs out well before it resets. Running
    /// out just before is within the noise of a forecast from one reading, so it stays quiet.
    private func warning(for limit: CodexLimit) -> Warning? {
        guard !limit.hasReset(at: now) else { return nil }
        if limit.isUsedUp { return .usedUp }
        guard isLive, case .runsOut(let date) = limit.window.pace(at: now),
            let resetsAt = limit.window.resetsAt, let duration = limit.window.duration,
            resetsAt.timeIntervalSince(date) > duration * Self.forecastMargin
        else { return nil }
        return .runsOut(date)
    }

    /// How far ahead of the reset, as a share of the window, a limit has to run out to be worth a warning.
    static let forecastMargin = 0.05

    /// The longest wording that fits on one line.
    private func warningLabel(_ warning: Warning) -> some View {
        let (texts, systemImage, color): ([String], String, Color) =
            switch warning {
            case .usedUp: (["Used up until it resets", "Used up"], "hourglass", Color.usage(percent: 100))
            case .runsOut(let date):
                (
                    [
                        "At this pace, runs out \(CodexFormat.moment(date, now: now))",
                        "Runs out \(CodexFormat.moment(date, now: now))", "Runs out early",
                    ], "exclamationmark.triangle.fill", warningColor
                )
            }
        return ViewThatFits(in: .horizontal) {
            ForEach(texts, id: \.self) { text in
                Label(text, systemImage: systemImage).labelStyle(TightLabelStyle()).lineLimit(1)
            }
        }
        .foregroundStyle(color)
    }

    /// `Resets in 2h 14m`, `Resets Fri 06:00`, or `Reset 14:20, waiting for Codex` once it has passed. `short` drops
    /// the verb.
    @ViewBuilder
    private func resetText(_ limit: CodexLimit, short: Bool) -> some View {
        if let resetsAt = limit.window.resetsAt {
            if resetsAt <= now {
                Text(short ? "Awaiting update" : "Reset \(CodexFormat.moment(resetsAt, now: now)), awaiting update")
            } else if resetsAt.timeIntervalSince(now) < 86_400 {
                let countdown = Formatting.countdown(to: resetsAt, now: now)
                Text(short ? "in \(countdown)" : "Resets in \(countdown)").monospacedDigit()
            } else {
                let moment = CodexFormat.moment(resetsAt, now: now)
                Text(short ? moment : "Resets \(moment)")
            }
        }
    }

    /// `in 2h`, `in 14m`, `Fri`; `new` once the window has reset. "in" keeps a countdown apart from a window's
    /// name (`5h`) right next to it.
    private func shortCountdown(_ limit: CodexLimit) -> String? {
        guard let resetsAt = limit.window.resetsAt else { return nil }
        if resetsAt <= now { return "new" }
        let countdown = Formatting.shortCountdown(to: resetsAt, now: now)
        return resetsAt.timeIntervalSince(now) < 86_400 ? "in \(countdown)" : countdown
    }

    // MARK: Tokens

    private var hasTokenHistory: Bool { state.usage != nil || state.sessionTokens != nil }

    private var todayTokens: Int64? { state.usage?.tokens(on: now) }

    /// Neutral colors, apart from the limits above: today's tokens, the lifetime total and two weeks of days.
    private var tokenHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    if let usage = state.usage {
                        Text("Tokens today").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Text(Formatting.compactCount(usage.tokens(on: now)))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        if let lifetime = usage.lifetimeTokens {
                            Text("\(Formatting.compactCount(lifetime)) lifetime")
                                .font(.system(size: 10.5))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    } else if let session = state.sessionTokens {
                        Text("Last session").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Text(Formatting.compactCount(session))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("tokens").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .fixedSize()
                if let usage = state.usage {
                    Spacer(minLength: 0)
                    let days = usage.dailyTotals(endingOn: now, days: Self.historyDays)
                    VStack(alignment: .trailing, spacing: 3) {
                        Sparkline(values: days, height: 24)
                            .frame(maxWidth: 124)
                        Text("\(Self.historyDays) days").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .help("Tokens per day over the last \(Self.historyDays) days")
                    .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    static let historyDays = 14

    private func todayLine(_ today: Int64) -> some View {
        ViewThatFits(in: .horizontal) {
            Label("\(Formatting.compactCount(today)) tokens today", systemImage: "chart.bar.xaxis")
            Label("\(Formatting.compactCount(today)) today", systemImage: "chart.bar.xaxis")
        }
        .labelStyle(TightLabelStyle())
        .font(.system(size: 9.5))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    // MARK: Plan and freshness

    /// The plan and anything else Codex can spend on the left, and how old the numbers are on the right when
    /// they aren't live. Not drawn when there's nothing to say.
    @ViewBuilder
    private var footer: some View {
        let extras = footerExtras
        if !extras.isEmpty || staleAge != nil {
            HStack(spacing: 6) {
                if !extras.isEmpty {
                    Text(extras.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .help(
                            "Your plan, credits that keep Codex going past its limits, and rate-limit resets you can "
                                + "redeem in Codex to start a limit over.")
                }
                Spacer(minLength: 4)
                if let age = staleAge {
                    Label(age, systemImage: "clock")
                        .labelStyle(TightLabelStyle())
                        .foregroundStyle(freshnessStyle)
                        .help(freshnessHelp)
                }
            }
            .font(.system(size: 10))
            .lineLimit(1)
        }
    }

    private var footerExtras: [String] {
        var extras: [String] = []
        if let plan = state.plan.flatMap(CodexFormat.planTitle) { extras.append(plan) }
        if let credits = state.rateLimits?.credits, credits.hasCredits || credits.isUnlimited {
            if credits.isUnlimited {
                extras.append("Unlimited credits")
            } else if let balance = credits.balance.flatMap(CodexFormat.credits) {
                extras.append("\(balance) credits")
            }
        }
        if let resets = state.resetCredits, resets > 0 {
            extras.append(resets == 1 ? "1 reset credit" : "\(resets) reset credits")
        }
        return extras
    }

    private var isStale: Bool { state.isStale(at: now) }

    /// `3h ago` when the numbers aren't live.
    private var staleAge: String? {
        guard !isLive, let capturedAt = state.limitsCapturedAt else { return nil }
        return CodexFormat.age(of: capturedAt, now: now)
    }

    private var freshnessStyle: AnyShapeStyle {
        isStale ? AnyShapeStyle(warningColor) : AnyShapeStyle(.secondary)
    }

    private var freshnessHelp: String {
        let source =
            state.source == .rolloutFile
            ? "From Codex's session logs, which update when Codex runs."
            : "codex app-server isn't answering right now."
        guard let problem = state.problem else { return source }
        return "\(source) \(problem)"
    }

    // MARK: Accessibility and tooltips

    /// `66 percent left, resets in 2 hours, 14 minutes. Runs out at 15:40 at this pace.`
    private func spokenValue(_ limit: CodexLimit) -> String {
        var parts: [String] = []
        if limit.hasReset(at: now) {
            parts.append("reset, new usage not reported yet")
        } else {
            parts.append("\(Int(shownPercent(limit).rounded())) percent \(reading.suffix)")
            if let resetsAt = limit.window.resetsAt {
                parts.append("resets in \(CodexFormat.spokenDuration(until: resetsAt, now: now))")
            }
        }
        var value = parts.joined(separator: ", ")
        switch warning(for: limit) {
        case .usedUp?: value += ". Used up until it resets"
        case .runsOut(let date)?: value += ". Runs out \(CodexFormat.moment(date, now: now)) at this pace"
        case nil: break
        }
        if let reason = blockedReason { value += ". \(reason)" }
        if let age = staleAge { value += ". As of \(age)" }
        return value
    }

    /// Every limit, the one that runs out first first.
    private func glanceSpokenValue(lead: CodexLimit) -> String {
        ([lead] + limits.filter { $0.id != lead.id }).map { "\($0.title): \(spokenValue($0))" }
            .joined(separator: ". ")
    }

    private func glanceHelp(lead: CodexLimit) -> String {
        var lines = limits.map { limit in
            limit.hasReset(at: now)
                ? "\(limit.title): reset, awaiting update"
                : "\(limit.title): \(Int(shownPercent(limit).rounded()))% \(reading.suffix)"
        }
        if let reason = blockedReason { lines.insert(reason, at: 0) }
        if let age = staleAge { lines.append("As of \(age)") }
        return lines.joined(separator: "\n")
    }
}

/// Text formats the Codex widget and its settings share.
enum CodexFormat {
    /// `14:20` today, `Fri 06:00` on another day.
    static func moment(_ date: Date, now: Date) -> String {
        Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// `just now`, `3m ago`, `2h ago`.
    static func age(of date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60
            ? "just now" : "\(Formatting.countdownLeadingUnit(to: now, now: date)) ago"
    }

    /// `2 hours, 14 minutes`, for VoiceOver.
    static func spokenDuration(until date: Date, now: Date) -> String {
        let seconds = max(60, (date.timeIntervalSince(now) / 60).rounded() * 60)
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2))
    }

    /// Codex's plan identifiers as people know them: `plus` → `Plus`, `prolite` → `Pro Lite`. `nil` for `unknown`.
    static func planTitle(_ plan: String) -> String? {
        switch plan.lowercased() {
        case "", "unknown": nil
        case "prolite": "Pro Lite"
        case "promax": "Pro Max"
        case "edu": "Edu"
        default: plan.split(separator: "_").map(\.capitalized).joined(separator: " ")
        }
    }

    /// A credit balance (sent as a decimal string) as a whole number: `1,250`.
    static func credits(_ balance: String) -> String? {
        guard let value = Double(balance), value.isFinite else { return nil }
        return value.rounded(.down).formatted(.number.precision(.fractionLength(0)))
    }
}
