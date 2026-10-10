import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let cursor = WidgetMetadata(
        title: "Cursor",
        systemImage: "cursorarrow",
        tint: .cursor,
        summary: "Cursor's included usage this billing cycle: Cursor models and API models, and whether they'll last."
    )
}

extension Color {
    /// A cool slate, since Cursor's own mark is black and white.
    fileprivate static let cursor = Color(red: 0.56, green: 0.65, blue: 0.86)
}

extension CursorSettings {
    var summary: String { refreshesFromCursor ? "Every \(refreshMinutes) min" : "Not connected" }
}

extension CursorUsagePool.Kind {
    /// For minimal and bar layouts.
    var shortTitle: String {
        switch self {
        case .cursorModels: "Cursor"
        case .otherModels: "API"
        case .included: "Plan"
        }
    }
}

// MARK: - Settings

struct CursorSettingsEditor: View {
    @Binding var settings: CursorSettings

    var body: some View {
        CursorFetchSettings(isOn: $settings.refreshesFromCursor, minutes: $settings.refreshMinutes)
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show on-demand spending", isOn: $settings.showsOnDemand)
            Text("Pay-as-you-go usage past the included pools, as a share of your spending limit.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The opt-in to fetch usage from Cursor on a timer, and how the last fetch went. Each widget that shows Cursor
/// usage has its own; the service fetches as often as the most frequent one that's showing asks.
struct CursorFetchSettings: View {
    @Binding var isOn: Bool
    @Binding var minutes: Int
    @Environment(CursorService.self) private var cursor

    /// The offered intervals, plus one set by hand in `config.json`, so the picker always shows the real value.
    private var minuteChoices: [Int] {
        Set(CursorSettings.refreshMinuteChoices + [minutes]).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Fetch usage from Cursor", isOn: $isOn)
            Picker("Every", selection: $minutes) {
                ForEach(minuteChoices, id: \.self) { Text("\($0) min").tag($0) }
            }
            .disabled(!isOn)
            caption(
                "Asks cursor.com for your plan's usage the way its Spending dashboard does, signed in as the Cursor "
                    + "app is (or the Cursor CLI, if the app isn't). The sign-in is read for each request and never "
                    + "stored or renewed. Cursor has no public usage API for individual plans, so this uses the "
                    + "dashboard's own endpoint and may stop working."
            )
            if isOn {
                status
            }
            caption("The editor, the CLI and cloud agents share the same pools; Cursor doesn't split usage by tool.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var status: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(cursor.problem != nil ? Color.orange : cursor.usage != nil ? .green : .secondary)
                .frame(width: 7, height: 7)
            Group {
                if let problem = cursor.problem {
                    Text("\(problem.title). \(problem.advice)")
                } else if let usage = cursor.usage {
                    let signIn = cursor.signInSource == .cli ? "Cursor CLI's" : "Cursor app's"
                    Text(
                        "Fetched \(usage.fetchedAt, format: .relative(presentation: .named)) with the \(signIn) sign-in"
                    )
                } else {
                    Text(cursor.isFetching ? "Fetching…" : "Waiting for the first fetch")
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Refresh", systemImage: "arrow.clockwise") { cursor.refreshNow() }
                .labelStyle(.iconOnly)
                .disabled(cursor.isFetching)
                .help("Fetch now")
        }
    }
}

// MARK: - Widget

/// Both included-usage pools side by side, each a meter over the billing cycle (one segment per week) with a tick
/// at the time already passed: fill running past the tick means the pool runs out before the cycle resets. Minimal
/// and bar layouts lead with the pool closest to running out.
struct CursorWidgetView: View {
    let settings: CursorSettings
    let layout: WidgetLayout
    @Environment(CursorService.self) private var cursor

    var body: some View {
        if !settings.refreshesFromCursor {
            setup
        } else if let usage = cursor.usage {
            // Countdowns, the time tick, staleness and the cycle rolling over all move on with the clock.
            TimelineView(.everyMinute) { context in
                let current = usage.current(at: context.date)
                if current.pools.isEmpty {
                    unlimited(current, now: context.date)
                } else {
                    switch layout {
                    case .regular: regular(current, now: context.date)
                    case .compact: compact(current, now: context.date)
                    case .minimal: minimal(current, now: context.date)
                    case .bar: bar(current, now: context.date)
                    }
                }
            }
        } else if let problem = cursor.problem {
            message(problem.title, detail: problem.advice, systemImage: "exclamationmark.circle")
        } else {
            message("Loading Cursor usage…", systemImage: "hourglass")
        }
    }

    // MARK: States

    private var setup: some View {
        message(
            "Cursor usage isn't connected",
            detail: "Turn on Fetch usage from Cursor in this widget's settings.",
            systemImage: "cursorarrow"
        )
    }

    @ViewBuilder
    private func message(_ title: String, detail: String? = nil, systemImage: String) -> some View {
        if layout.isGlanceable {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .help([title, detail].compactMap(\.self).joined(separator: ". "))
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout)
                if let detail {
                    Text(detail).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func unlimited(_ usage: CursorUsage, now: Date) -> some View {
        if layout.isGlanceable {
            Image(systemName: "infinity").foregroundStyle(.secondary).help("Unlimited plan")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                planBadge(usage)
                Label("Unlimited plan", systemImage: "infinity").font(.callout).lineLimit(1)
                if layout == .regular { footer(usage, now: now) }
            }
        }
    }

    // MARK: Layouts

    private func regular(_ usage: CursorUsage, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                planBadge(usage)
                Spacer(minLength: 0)
                Text(cycleText(usage, now: now))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ForEach(usage.pools) { pool in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(pool.kind.title).font(.system(size: 11.5, weight: .medium))
                        Spacer(minLength: 0)
                        percentText(pool.window.usedPercent, size: 20)
                    }
                    meter(pool.window, now: now, height: 6)
                    if isRunningOut(pool.window, now: now) {
                        forecast(pool.window, now: now).font(.system(size: 10.5)).lineLimit(1)
                    }
                }
                .help(help(for: pool))
            }
            if settings.showsOnDemand, let onDemand = usage.onDemand, onDemand.isEnabled {
                onDemandRow(onDemand)
            }
            footer(usage, now: now)
        }
    }

    private func compact(_ usage: CursorUsage, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(usage.pools) { pool in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(pool.kind.title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        percentText(pool.window.usedPercent, size: 13)
                    }
                    meter(pool.window, now: now, height: 5)
                    // Only a pool in trouble speaks up here.
                    if isRunningOut(pool.window, now: now) {
                        forecast(pool.window, now: now).font(.system(size: 9.5)).lineLimit(1)
                    }
                }
                .help(help(for: pool))
            }
            if settings.showsOnDemand, let percent = usage.onDemand?.usedPercent, usage.onDemand?.isEnabled == true {
                Text("On-demand \(Int(percent.rounded()))% of limit")
                    .font(.system(size: 9.5))
                    .foregroundStyle(percent >= Color.usageWarningThreshold ? warningColor : .secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Text(cycleText(usage, now: now, withDate: false))
                if cursor.isStale(at: now) {
                    Spacer(minLength: 4)
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(warningColor)
                        .help(staleHelp(usage, now: now))
                }
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    /// The tightest pool as a tick gauge with its percentage inside, its name, the countdown to the reset, and the
    /// other pool as a tiny meter.
    @ViewBuilder
    private func minimal(_ usage: CursorUsage, now: Date) -> some View {
        if let lead = usage.tightestPool {
            VStack(spacing: 4) {
                TickGauge(percent: lead.window.usedPercent, elapsedFraction: lead.window.elapsedFraction(at: now))
                    .overlay {
                        Text("\(Int(lead.window.usedPercent.rounded()))")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: 24)
                            .contentTransition(.numericText(value: lead.window.usedPercent))
                            .animation(Motion.gentle, value: lead.window.usedPercent)
                    }
                    .opacity(cursor.isStale(at: now) ? 0.55 : 1)
                Text(lead.kind.shortTitle)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(shortReset(lead.window, now: now))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isRunningOut(lead.window, now: now) ? warningColor : .secondary)
                ForEach(usage.pools.filter { $0.kind != lead.kind }) { other in
                    SegmentedMeter(percent: other.window.usedPercent, segments: 4, height: 3, spacing: 1.5)
                        .frame(width: 36)
                        .help("\(other.kind.title): \(Int(other.window.usedPercent.rounded()))%")
                }
            }
            .help(help(for: lead))
        }
    }

    private func bar(_ usage: CursorUsage, now: Date) -> some View {
        HStack(spacing: 7) {
            if let lead = usage.tightestPool {
                TickGauge(
                    percent: lead.window.usedPercent, elapsedFraction: lead.window.elapsedFraction(at: now),
                    diameter: 22, ticks: 24, innerFraction: 0.5)
                VStack(alignment: .leading, spacing: 0) {
                    percentText(lead.window.usedPercent, size: 13)
                    Text(lead.kind.shortTitle).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                }
                .help(help(for: lead))
                ForEach(usage.pools.filter { $0.kind != lead.kind }) { other in
                    VStack(spacing: 3) {
                        percentText(other.window.usedPercent, size: 10.5).foregroundStyle(.secondary)
                        SegmentedMeter(percent: other.window.usedPercent, segments: 4, height: 2.5, spacing: 1)
                    }
                    .frame(width: 30)
                    .help(help(for: other))
                }
                Text(shortReset(lead.window, now: now))
                    .font(.system(size: 10.5, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(cursor.isStale(at: now) ? warningColor : .secondary)
                    .help(cursor.isStale(at: now) ? staleHelp(usage, now: now) : "Until the billing cycle resets")
            }
        }
    }

    // MARK: Parts

    private var warningColor: Color { .usage(percent: 75) }

    /// One segment per week of the billing cycle.
    private func meter(_ window: RateLimitWindow, now: Date, height: CGFloat) -> some View {
        let weeks = window.duration.map { Int(($0 / (7 * 86_400)).rounded()) } ?? 4
        return SegmentedMeter(
            percent: window.usedPercent,
            segments: min(max(weeks, 1), 6),
            elapsedFraction: window.elapsedFraction(at: now),
            height: height,
            spacing: 2.5
        )
    }

    private func isRunningOut(_ window: RateLimitWindow, now: Date) -> Bool {
        switch window.pace(at: now) {
        case .runsOut, .reached: true
        case .lasts, .unknown: false
        }
    }

    @ViewBuilder
    private func forecast(_ window: RateLimitWindow, now: Date) -> some View {
        switch window.pace(at: now) {
        case .unknown, .lasts:
            EmptyView()
        case .runsOut(let date):
            Label("At this pace, runs out \(day(date, now: now))", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(TightLabelStyle())
                .foregroundStyle(warningColor)
        case .reached:
            Label(
                settings.showsOnDemand && cursor.usage?.onDemand?.isEnabled == true
                    ? "Used up · on-demand from here" : "Used up until the reset",
                systemImage: "hourglass"
            )
            .labelStyle(TightLabelStyle())
            .foregroundStyle(Color.usage(percent: 100))
        }
    }

    private func onDemandRow(_ onDemand: CursorSpending) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("On-demand").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let percent = onDemand.usedPercent {
                    Text("\(Int(percent.rounded()))% of limit")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                } else {
                    Text("On · no limit").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            if let percent = onDemand.usedPercent {
                UsageBar(percent: percent, height: 4)
            }
        }
        .help("Pay-as-you-go usage past the included pools, billed monthly at API rates.")
    }

    /// `cursor.com · 3m ago`, in the warning color once it's out of date.
    private func footer(_ usage: CursorUsage, now: Date) -> some View {
        let isStale = cursor.isStale(at: now)
        return HStack(spacing: 4) {
            Spacer()
            if isStale {
                Image(systemName: "clock.badge.exclamationmark")
            }
            Text("cursor.com · \(age(of: usage, now: now))")
        }
        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
        .foregroundStyle(isStale ? AnyShapeStyle(warningColor) : AnyShapeStyle(.tertiary))
        .help(isStale ? staleHelp(usage, now: now) : sourceHelp)
    }

    private var sourceHelp: String {
        "Fetched from cursor.com with the " + (cursor.signInSource == .cli ? "Cursor CLI's" : "Cursor app's")
            + " sign-in"
    }

    private func staleHelp(_ usage: CursorUsage, now: Date) -> String {
        let fetched = "Last fetched \(age(of: usage, now: now))"
        guard let problem = cursor.problem else { return fetched }
        return "\(fetched). \(problem.title). \(problem.advice)"
    }

    private func age(of usage: CursorUsage, now: Date) -> String {
        now.timeIntervalSince(usage.fetchedAt) < 60
            ? "just now" : "\(Formatting.countdownLeadingUnit(to: now, now: usage.fetchedAt)) ago"
    }

    private func help(for pool: CursorUsagePool) -> String {
        [pool.kind.explanation, pool.message].compactMap(\.self).joined(separator: "\n")
    }

    /// `Resets in 18d · Oct 28`
    private func cycleText(_ usage: CursorUsage, now: Date, withDate: Bool = true) -> String {
        if usage.cycleHasEnded(at: now) { return "New billing cycle" }
        guard let end = usage.billingCycle?.end else { return "Monthly" }
        let countdown = "Resets in \(Formatting.countdownLeadingUnit(to: end, now: now))"
        return withDate ? "\(countdown) · \(day(end, now: now))" : countdown
    }

    /// `18d`, or `new` once the cycle has rolled over.
    private func shortReset(_ window: RateLimitWindow, now: Date) -> String {
        guard let resetsAt = window.resetsAt else { return "new" }
        return Formatting.countdownLeadingUnit(to: resetsAt, now: now)
    }

    /// `14:20` today, `Oct 28` on another day.
    private func day(_ date: Date, now: Date) -> String {
        Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func percentText(_ percent: Double, size: CGFloat) -> some View {
        Text("\(Int(percent.rounded()))%")
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText(value: percent))
            .animation(Motion.gentle, value: percent)
    }

    @ViewBuilder
    private func planBadge(_ usage: CursorUsage) -> some View {
        if let plan = usage.planName {
            Text(plan.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Color.cursor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.cursor.opacity(0.16)))
                .help(usage.limitType == "team" ? "Usage from your team plan" : "Your Cursor plan")
        }
    }
}
