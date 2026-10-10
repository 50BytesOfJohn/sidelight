import AppKit
import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let claudeCode = WidgetMetadata(
        title: "Claude Code",
        systemImage: "asterisk",
        tint: .claude,
        summary: "Claude plan limits: the 5-hour session and the week, when they reset, and whether they'll last."
    )
}

extension Color {
    /// Claude's terracotta.
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
}

extension ClaudeCodeSettings {
    var summary: String {
        let limits = showsWeeklyLimit ? "Session + week" : "Session only"
        return refreshesFromAnthropic ? "\(limits) · every \(refreshMinutes) min" : limits
    }
}

struct ClaudeCodeSettingsEditor: View {
    @Binding var settings: ClaudeCodeSettings

    var body: some View {
        Toggle("Show weekly limit", isOn: $settings.showsWeeklyLimit)
        Divider()
        AnthropicRefreshSettings(isOn: $settings.refreshesFromAnthropic, minutes: $settings.refreshMinutes)
        Divider()
        StatusLineSetup()
    }
}

/// The opt-in to fetch usage from Anthropic on a timer, and how the last fetch went. Each widget that shows Claude
/// usage has its own; the service fetches as often as the most frequent one that's showing asks.
struct AnthropicRefreshSettings: View {
    @Binding var isOn: Bool
    @Binding var minutes: Int
    @Environment(ClaudeCodeService.self) private var claude

    /// The offered intervals, plus one set by hand in `config.json`, so the picker always shows the real value.
    private var minuteChoices: [Int] {
        Set(ClaudeCodeSettings.refreshMinuteChoices + [minutes]).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Refresh from Anthropic", isOn: $isOn)
            Picker("Every", selection: $minutes) {
                ForEach(minuteChoices, id: \.self) { Text("\($0) min").tag($0) }
            }
            .disabled(!isOn)
            Text(
                "Asks Anthropic for your plan's usage the way /usage does, signed in as Claude Code is, so it also "
                    + "counts claude.ai and your other devices. The sign-in is read from your keychain for each "
                    + "request and never stored. It's an undocumented endpoint, so it may stop working."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if isOn {
                status
            }
        }
    }

    private var status: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(
                    claude.anthropicProblem != nil ? Color.orange : claude.anthropicUsage != nil ? .green : .secondary
                )
                .frame(width: 7, height: 7)
            Group {
                if let problem = claude.anthropicProblem {
                    Text(problem.message)
                } else if let usage = claude.anthropicUsage {
                    Text("Fetched \(usage.capturedAt, format: .relative(presentation: .named))")
                } else {
                    Text("Waiting for the first fetch")
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// How to connect Claude Code's status line for live limits, and whether it is.
struct StatusLineSetup: View {
    @Environment(ClaudeCodeService.self) private var claude
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            status
            if let script = ClaudeCodeService.bridgeScriptURL {
                let snippet = Self.snippet(script: script)
                Text(
                    "Claude Code hands its status line your plan's limits after every response. For live updates, "
                        + "point it at Sidelight's bridge in ~/.claude/settings.json:"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(snippet)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                Button(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    didCopy = true
                }
                Text("Already have a status line? Put its command after the bridge's path and it keeps working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(claude.statusLineUsage != nil ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Group {
                if let live = claude.statusLineUsage {
                    Text("Live · updated \(live.capturedAt, format: .relative(presentation: .named))")
                } else if claude.accountState?.usage != nil {
                    Text("Not live · showing what /usage last fetched")
                } else {
                    Text("Not connected")
                }
            }
            .font(.callout.weight(.medium))
        }
    }

    private static func snippet(script: URL) -> String {
        """
        "statusLine": {
          "type": "command",
          "command": "'\(script.path(percentEncoded: false))'"
        }
        """
    }
}

/// The session as the hero: a big number over a five-segment meter (one per hour) with a tick at the current
/// time, and a forecast of whether it lasts. The week sits below at a smaller scale, seven segments for seven
/// days. Minimal and bar layouts trade the meters for a tick gauge.
struct ClaudeCodeWidgetView: View {
    let settings: ClaudeCodeSettings
    let layout: WidgetLayout
    @Environment(ClaudeCodeService.self) private var claude

    var body: some View {
        if let usage = claude.usage {
            // Countdowns, the time tick and windows rolling over all move on with the clock.
            TimelineView(.everyMinute) { context in
                let current = usage.current(at: context.date)
                if let session = current.session {
                    let weekly = settings.showsWeeklyLimit ? current.weekly : nil
                    switch layout {
                    case .regular: regular(session: session, weekly: weekly, usage: current, now: context.date)
                    case .compact: compact(session: session, weekly: weekly, now: context.date)
                    case .minimal: minimal(session: session, weekly: weekly, now: context.date)
                    case .bar: bar(session: session, weekly: weekly, now: context.date)
                    }
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if layout.isGlanceable {
            Image(systemName: claude.hasLoaded ? "asterisk" : "hourglass").foregroundStyle(.secondary)
        } else if claude.hasLoaded {
            VStack(alignment: .leading, spacing: 3) {
                Text("No Claude Code limits yet").font(.callout)
                Text("Connect its status line in this widget's settings.").font(.caption)
            }
            .foregroundStyle(.secondary)
        } else {
            Text("Loading Claude Code usage…").font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Layouts

    private func regular(
        session: RateLimitWindow, weekly: RateLimitWindow?, usage: ClaudeCodeUsage, now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    largePercent(session.usedPercent)
                    Text("of session").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    planBadge
                }
                SegmentedMeter(
                    percent: session.usedPercent,
                    segments: 5,
                    elapsedFraction: session.elapsedFraction(at: now),
                    height: 8
                )
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(sessionReset(session, now: now)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    forecast(session, now: now)
                }
                .font(.system(size: 10.5))
                .lineLimit(1)
            }
            if let weekly {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Week").font(.system(size: 11.5, weight: .medium))
                        percentText(weekly.usedPercent, size: 11.5)
                        Spacer(minLength: 0)
                        if let resetsAt = weekly.resetsAt {
                            Text("Resets \(moment(resetsAt, now: now))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    SegmentedMeter(
                        percent: weekly.usedPercent,
                        segments: 7,
                        elapsedFraction: weekly.elapsedFraction(at: now),
                        height: 5,
                        spacing: 2.5
                    )
                    // The week only speaks up when it's in trouble.
                    if isRunningOut(weekly, now: now) {
                        forecast(weekly, now: now).font(.system(size: 10.5))
                    }
                }
            }
            HStack {
                Spacer()
                Text(source(of: usage, now: now))
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .help(sourceHelp(usage.source))
            }
        }
    }

    private func compact(session: RateLimitWindow, weekly: RateLimitWindow?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            compactRow("Session", session, segments: 5, now: now) {
                if isRunningOut(session, now: now) {
                    forecast(session, now: now)
                } else {
                    Text(sessionReset(session, now: now)).foregroundStyle(.secondary)
                }
            }
            if let weekly {
                compactRow("Week", weekly, segments: 7, now: now) {
                    if isRunningOut(weekly, now: now) {
                        forecast(weekly, now: now)
                    } else if let resetsAt = weekly.resetsAt {
                        Text("Resets \(moment(resetsAt, now: now))").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func compactRow(
        _ title: String, _ window: RateLimitWindow, segments: Int, now: Date,
        @ViewBuilder detail: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                percentText(window.usedPercent, size: 13)
            }
            SegmentedMeter(
                percent: window.usedPercent,
                segments: segments,
                elapsedFraction: window.elapsedFraction(at: now),
                height: 5,
                spacing: 2
            )
            detail().font(.system(size: 9.5)).lineLimit(1)
        }
    }

    /// The session as a tick gauge with its percentage inside, the countdown, and the week as a tiny meter.
    private func minimal(session: RateLimitWindow, weekly: RateLimitWindow?, now: Date) -> some View {
        VStack(spacing: 5) {
            TickGauge(percent: session.usedPercent, elapsedFraction: session.elapsedFraction(at: now), diameter: 44)
                .overlay {
                    Text("\(Int(session.usedPercent.rounded()))")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: 24)
                        .contentTransition(.numericText(value: session.usedPercent))
                        .animation(Motion.gentle, value: session.usedPercent)
                }
            Text(session.resetsAt == nil ? "fresh" : Formatting.countdown(to: session.resetsAt, now: now))
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isRunningOut(session, now: now) ? warningColor : .secondary)
            if let weekly {
                SegmentedMeter(percent: weekly.usedPercent, segments: 7, height: 3, spacing: 1.5)
                    .frame(width: 36)
                    .help("Week: \(Int(weekly.usedPercent.rounded()))%")
            }
        }
    }

    private func bar(session: RateLimitWindow, weekly: RateLimitWindow?, now: Date) -> some View {
        HStack(spacing: 7) {
            TickGauge(
                percent: session.usedPercent, elapsedFraction: session.elapsedFraction(at: now), diameter: 22,
                ticks: 24, innerFraction: 0.5)
            percentText(session.usedPercent, size: 13)
            if let resetsAt = session.resetsAt {
                Text(Formatting.countdown(to: resetsAt, now: now))
                    .font(.system(size: 10.5, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isRunningOut(session, now: now) ? warningColor : .secondary)
            }
            if let weekly {
                VStack(spacing: 3) {
                    percentText(weekly.usedPercent, size: 10.5).foregroundStyle(.secondary)
                    SegmentedMeter(percent: weekly.usedPercent, segments: 7, height: 2.5, spacing: 1)
                }
                .frame(width: 30)
                .help("Week")
            }
        }
    }

    // MARK: Parts

    private var warningColor: Color { .usage(percent: 75) }

    private func isRunningOut(_ window: RateLimitWindow, now: Date) -> Bool {
        switch window.pace(at: now) {
        case .runsOut, .reached: true
        case .lasts, .unknown: false
        }
    }

    @ViewBuilder
    private func forecast(_ window: RateLimitWindow, now: Date) -> some View {
        switch window.pace(at: now) {
        case .unknown:
            EmptyView()
        case .lasts:
            Label("Lasts until reset", systemImage: "checkmark")
                .labelStyle(TightLabelStyle())
                .foregroundStyle(.secondary)
        case .runsOut(let date):
            Label("Runs out \(moment(date, now: now))", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(TightLabelStyle())
                .foregroundStyle(warningColor)
        case .reached:
            Label("Limit reached", systemImage: "hourglass")
                .labelStyle(TightLabelStyle())
                .foregroundStyle(Color.usage(percent: 100))
        }
    }

    private func sessionReset(_ session: RateLimitWindow, now: Date) -> String {
        guard let resetsAt = session.resetsAt else { return "Starts with your next message" }
        return "Resets in \(Formatting.countdown(to: resetsAt, now: now))"
    }

    /// `14:20` today, `Fri 06:00` on another day.
    private func moment(_ date: Date, now: Date) -> String {
        Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// `status line · 3m ago`
    private func source(of usage: ClaudeCodeUsage, now: Date) -> String {
        let age =
            now.timeIntervalSince(usage.capturedAt) < 60
            ? "just now" : "\(Formatting.countdownLeadingUnit(to: now, now: usage.capturedAt)) ago"
        return switch usage.source {
        case .statusLine: "status line · \(age)"
        case .usageCache: "/usage · \(age)"
        case .anthropic: "anthropic · \(age)"
        }
    }

    private func sourceHelp(_ source: ClaudeCodeUsage.Source) -> String {
        switch source {
        case .statusLine: "From Claude Code's status line"
        case .usageCache: "What Claude Code's /usage last fetched. Connect its status line for live limits."
        case .anthropic: "Fetched from Anthropic with Claude Code's sign-in"
        }
    }

    private func largePercent(_ percent: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("\(Int(percent.rounded()))")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: percent))
            Text("%").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
        }
        .animation(Motion.gentle, value: percent)
    }

    private func percentText(_ percent: Double, size: CGFloat) -> some View {
        Text("\(Int(percent.rounded()))%")
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText(value: percent))
            .animation(Motion.gentle, value: percent)
    }

    @ViewBuilder
    private var planBadge: some View {
        if let plan = claude.plan {
            Text(plan.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Color.claude)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.claude.opacity(0.16)))
        }
    }
}
