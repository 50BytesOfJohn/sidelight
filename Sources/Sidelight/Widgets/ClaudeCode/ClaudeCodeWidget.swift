import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let claudeCode = WidgetMetadata(
        title: "Claude Code",
        systemImage: "asterisk",
        tint: .claude,
        summary: "Claude plan limits",
        details: "The 5-hour session and the week, when they reset, and whether they'll last."
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
        AccountPicker(provider: .claudeCode, selection: $settings.account)
        Toggle("Show weekly limit", isOn: $settings.showsWeeklyLimit)
        AnthropicRefreshSettings(
            account: settings.account, isOn: $settings.refreshesFromAnthropic, minutes: $settings.refreshMinutes)
        StatusLineSetup(account: settings.account)
    }
}

/// The opt-in to fetch usage from Anthropic on a timer, and how the last fetch for the widget's account went. Each
/// widget that shows Claude usage has its own; each account fetches as often as the most frequent of its widgets
/// that's showing asks.
struct AnthropicRefreshSettings: View {
    /// The widget's Claude account: `nil` for the default one.
    let account: AccountID?
    @Binding var isOn: Bool
    @Binding var minutes: Int

    var body: some View {
        AnthropicRefreshPicker(isOn: $isOn, minutes: $minutes)
        if isOn {
            AnthropicFetchStatus(account: account)
        }
    }
}

/// The opt-in to fetch Claude usage from Anthropic on a timer, and how often.
struct AnthropicRefreshPicker: View {
    var title = "Refresh from Anthropic"
    @Binding var isOn: Bool
    @Binding var minutes: Int

    var body: some View {
        RefreshIntervalPicker(
            title: title,
            info: "Asks Anthropic for your plan's usage like /usage does, signed in as Claude Code is, so it also "
                + "counts claude.ai and your other devices. Sidelight reads the sign-in from your keychain for each "
                + "request and never stores it. The endpoint is undocumented, so this may stop working.",
            isOn: $isOn, minutes: $minutes, choices: ClaudeCodeSettings.refreshMinuteChoices)
    }
}

/// How the last fetch from Anthropic went for a Claude account.
struct AnthropicFetchStatus: View {
    /// `nil` for the default account.
    let account: AccountID?
    @Environment(AccountStore.self) private var accounts
    @Environment(ClaudeCodeService.self) private var service

    private var claude: ClaudeCodeAccount? { service.account(for: account, in: accounts) }

    var body: some View {
        StatusRow(
            color: claude?.anthropicProblem != nil ? Color.orange : claude?.anthropicUsage != nil ? .green : .secondary,
            alignment: .firstTextBaseline
        ) {
            if let problem = claude?.anthropicProblem {
                Text(problem.message)
            } else if let usage = claude?.anthropicUsage {
                Text("Fetched \(usage.capturedAt, format: .relative(presentation: .named))")
            } else {
                Text("Waiting for the first fetch")
            }
        }
    }
}

/// How to connect Claude Code's status line for live limits, and whether it is, for the widget's account.
struct StatusLineSetup: View {
    /// The widget's Claude account: `nil` for the default one.
    let account: AccountID?
    @Environment(AccountStore.self) private var accounts
    @Environment(ClaudeCodeService.self) private var service
    @State private var didCopy = false

    private var claude: ClaudeCodeAccount? { service.account(for: account, in: accounts) }

    /// Where Claude Code keeps the account, whose settings name the status line.
    private var profile: ClaudeCodeProfile {
        accounts.resolve(account, at: .claudeCode).accountID.flatMap(accounts.claudeCodeProfile) ?? .standard
    }

    var body: some View {
        status
        if let script = ClaudeCodeService.bridgeScriptURL {
            ExpandableRow(title: "Set up live limits") {
                let snippet = Self.snippet(script: script)
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "Claude Code passes your plan's limits to its status line after every response. Point the "
                            + "status line at Sidelight's bridge in \(profile.displayPath)/settings.json:"
                    )
                    .settingsFootnote()
                    Text(snippet)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                    HStack {
                        Button(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc") {
                            SessionHost.copy(snippet)
                            didCopy = true
                        }
                        Spacer()
                        InfoButton(
                            "Already have a status line? Put its command after the bridge's path and it keeps "
                                + "working.")
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var status: some View {
        StatusRow(color: claude?.statusLineUsage != nil ? Color.green : Color.secondary.opacity(0.5)) {
            Group {
                if let live = claude?.statusLineUsage {
                    Text("Status line live · updated \(live.capturedAt, format: .relative(presentation: .named))")
                } else if claude?.accountState?.usage != nil {
                    Text("Status line not live · showing the last /usage")
                } else {
                    Text("Status line not connected")
                }
            }
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
    @Environment(AccountStore.self) private var accounts
    @Environment(ClaudeCodeService.self) private var service

    var body: some View {
        // Limits Claude Code saved still show while its sign-in needs renewing: using Claude Code renews it.
        AccountGate(reference: settings.account, provider: .claudeCode, layout: layout, requiresSignIn: false) { id in
            ClaudeCodeUsageView(
                claude: service.account(id), settings: settings, layout: layout,
                accountName: accounts.accounts(of: .claudeCode).count > 1 ? accounts.account(id)?.name : nil)
        }
    }
}

/// One Claude account's limits, in the widget's layout.
private struct ClaudeCodeUsageView: View {
    /// `nil` until Sidelight reads the account.
    let claude: ClaudeCodeAccount?
    let settings: ClaudeCodeSettings
    let layout: WidgetLayout
    /// Shown with the source, to tell accounts apart once there are several.
    let accountName: String?

    var body: some View {
        if let claude, let usage = claude.usage {
            // Countdowns, the time tick and windows rolling over all move on with the clock.
            WidgetClock { now in
                let current = usage.current(at: now)
                if let session = current.session {
                    let weekly = settings.showsWeeklyLimit ? current.weekly : nil
                    switch layout {
                    case .regular: regular(session: session, weekly: weekly, usage: current, now: now)
                    case .compact: compact(session: session, weekly: weekly, now: now)
                    case .minimal: minimal(session: session, weekly: weekly, now: now)
                    case .bar: bar(session: session, weekly: weekly, now: now)
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
        if claude?.hasLoaded == true {
            WidgetMessage(
                title: "No Claude Code limits yet", detail: "Connect its status line in this widget's settings.",
                systemImage: "asterisk", layout: layout, trimsCompact: false, detailLineLimit: nil)
        } else {
            WidgetMessage(
                title: "Loading Claude Code usage…", systemImage: "hourglass", layout: layout, trimsCompact: false)
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
                        PercentText(percent: weekly.usedPercent, size: 11.5)
                        Spacer(minLength: 0)
                        if let resetsAt = weekly.resetsAt {
                            Text("Resets \(UsageFormat.moment(resetsAt, now: now))")
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
                    if weekly.pace(at: now).isRunningOut {
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
                if session.pace(at: now).isRunningOut {
                    forecast(session, now: now)
                } else {
                    Text(sessionReset(session, now: now)).foregroundStyle(.secondary)
                }
            }
            if let weekly {
                compactRow("Week", weekly, segments: 7, now: now) {
                    if weekly.pace(at: now).isRunningOut {
                        forecast(weekly, now: now)
                    } else if let resetsAt = weekly.resetsAt {
                        Text("Resets \(UsageFormat.moment(resetsAt, now: now))").foregroundStyle(.secondary)
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
                PercentText(percent: window.usedPercent, size: 13)
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
            PercentGauge(percent: session.usedPercent, elapsedFraction: session.elapsedFraction(at: now), diameter: 44)
            Text(session.resetsAt == nil ? "fresh" : Formatting.countdown(to: session.resetsAt, now: now))
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(session.pace(at: now).isRunningOut ? Color.usageWarning : .secondary)
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
            PercentText(percent: session.usedPercent, size: 13)
            if let resetsAt = session.resetsAt {
                Text(Formatting.countdown(to: resetsAt, now: now))
                    .font(.system(size: 10.5, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(session.pace(at: now).isRunningOut ? Color.usageWarning : .secondary)
            }
            if let weekly {
                VStack(spacing: 3) {
                    PercentText(percent: weekly.usedPercent, size: 10.5).foregroundStyle(.secondary)
                    SegmentedMeter(percent: weekly.usedPercent, segments: 7, height: 2.5, spacing: 1)
                }
                .frame(width: 30)
                .help("Week")
            }
        }
    }

    // MARK: Parts

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
            Label("Runs out \(UsageFormat.moment(date, now: now))", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(TightLabelStyle())
                .foregroundStyle(Color.usageWarning)
        case .reached:
            Label("Limit reached", systemImage: "hourglass")
                .labelStyle(TightLabelStyle())
                .foregroundStyle(Color.usageCritical)
        }
    }

    private func sessionReset(_ session: RateLimitWindow, now: Date) -> String {
        guard let resetsAt = session.resetsAt else { return "Starts with your next message" }
        return "Resets in \(Formatting.countdown(to: resetsAt, now: now))"
    }

    /// `status line · 3m ago`, after the account's name once there are several.
    private func source(of usage: ClaudeCodeUsage, now: Date) -> String {
        let age = UsageFormat.age(of: usage.capturedAt, now: now)
        let source =
            switch usage.source {
            case .statusLine: "status line · \(age)"
            case .usageCache: "/usage · \(age)"
            case .anthropic: "anthropic · \(age)"
            }
        return [accountName?.lowercased(), source].compactMap(\.self).joined(separator: " · ")
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

    @ViewBuilder
    private var planBadge: some View {
        if let plan = claude?.plan {
            PlanBadge(name: plan, tint: .claude)
        }
    }
}
