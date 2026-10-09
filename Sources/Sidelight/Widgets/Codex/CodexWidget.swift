import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let codex = WidgetMetadata(
        title: "Codex",
        systemImage: "chart.pie",
        tint: .orange,
        summary: "Codex 5-hour and weekly rate limits, resets, tokens."
    )
}

extension CodexSettings {
    var summary: String { showsWeeklyLimit ? "5 h + weekly" : "5 h only" }
}

struct CodexSettingsEditor: View {
    @Binding var settings: CodexSettings

    var body: some View {
        Toggle("Show weekly limit", isOn: $settings.showsWeeklyLimit)
    }
}

struct CodexWidgetView: View {
    let settings: CodexSettings
    let layout: WidgetLayout
    @Environment(CodexService.self) private var codex

    var body: some View {
        if let fiveHour = codex.fiveHourWindow {
            let weekly = settings.showsWeeklyLimit ? codex.weeklyWindow : nil
            switch layout {
            case .regular: regular(fiveHour: fiveHour, weekly: weekly)
            case .compact: compact(fiveHour: fiveHour, weekly: weekly)
            case .minimal: minimal(fiveHour: fiveHour, weekly: weekly)
            case .bar: bar(fiveHour: fiveHour, weekly: weekly)
            }
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        let isUnavailable = codex.source == .unavailable
        if layout.isGlanceable {
            Image(systemName: isUnavailable ? "exclamationmark.circle" : "hourglass").foregroundStyle(.secondary)
        } else {
            Text(isUnavailable ? "No Codex data" : "Loading Codex usage…").font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Big ring with plan, credits and countdown; weekly bar; tokens with a 14-day sparkline.
    private func regular(fiveHour: RateLimitWindow, weekly: RateLimitWindow?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                UsageRing(percent: fiveHour.usedPercent)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        planBadge
                        if let credits = codex.resetCredits, credits > 0 {
                            Label("\(credits)", systemImage: "arrow.counterclockwise.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(credits)))
                                .foregroundStyle(.secondary)
                                .help("\(credits) rate-limit reset credits available")
                        }
                    }
                    TimelineView(.everyMinute) { context in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("5h resets in").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            Text(Formatting.countdown(to: fiveHour.resetsAt, now: context.date))
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if let weekly {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Weekly").font(.system(size: 11.5, weight: .medium))
                        percentText(weekly.usedPercent, size: 11.5)
                        Spacer()
                        TimelineView(.everyMinute) { context in
                            Text("resets in \(Formatting.countdown(to: weekly.resetsAt, now: context.date))")
                                .font(.system(size: 10.5))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    UsageBar(percent: weekly.usedPercent)
                }
            }
            if codex.lifetimeTokens != nil || codex.sessionTokens != nil {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 1) {
                        if let today = codex.todayTokens { tokenStat("Today", today) }
                        if let lifetime = codex.lifetimeTokens { tokenStat("Lifetime", lifetime) }
                        if let session = codex.sessionTokens, codex.source == .rolloutFile {
                            tokenStat("Session", session)
                        }
                    }
                    Spacer()
                    if !codex.dailyTokens.isEmpty {
                        Sparkline(values: codex.dailyTokens).frame(width: 120)
                    }
                }
            }
            HStack {
                Spacer()
                Text(codex.source.title)
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Mid-size ring, countdown, thin weekly bar.
    private func compact(fiveHour: RateLimitWindow, weekly: RateLimitWindow?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                UsageRing(percent: fiveHour.usedPercent, diameter: 54, lineWidth: 6, caption: "5h", fontSize: 16)
                VStack(alignment: .leading, spacing: 3) {
                    planBadge
                    TimelineView(.everyMinute) { context in
                        Text(Formatting.countdown(to: fiveHour.resetsAt, now: context.date))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    Text("until reset").font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let weekly {
                HStack(spacing: 6) {
                    Text("Wk").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    UsageBar(percent: weekly.usedPercent, height: 5)
                    percentText(weekly.usedPercent, size: 10)
                }
            }
        }
    }

    /// Small ring with the percentage inside; weekly as a thin inner ring.
    private func minimal(fiveHour: RateLimitWindow, weekly: RateLimitWindow?) -> some View {
        VStack(spacing: 4) {
            UsageRing(
                percent: fiveHour.usedPercent,
                innerPercent: weekly?.usedPercent,
                diameter: 46,
                lineWidth: 5,
                caption: nil,
                fontSize: 13
            )
            TimelineView(.everyMinute) { context in
                Text(Formatting.countdownLeadingUnit(to: fiveHour.resetsAt, now: context.date))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Tiny ring, percentage, and a dot for the weekly limit.
    private func bar(fiveHour: RateLimitWindow, weekly: RateLimitWindow?) -> some View {
        HStack(spacing: 6) {
            UsageRing(
                percent: fiveHour.usedPercent,
                innerPercent: weekly?.usedPercent,
                diameter: 24,
                lineWidth: 3.5,
                showsLabel: false
            )
            percentText(fiveHour.usedPercent, size: 13)
            if let weekly {
                Circle().fill(Color.usage(percent: weekly.usedPercent)).frame(width: 6, height: 6)
                Text("\(Int(weekly.usedPercent.rounded()))%")
                    .font(.system(size: 10.5, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .animation(Motion.gentle, value: fiveHour.usedPercent)
    }

    @ViewBuilder
    private var planBadge: some View {
        if let plan = codex.plan {
            Text(plan.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(
                        LinearGradient(
                            colors: [.purple.opacity(0.85), .blue.opacity(0.85)], startPoint: .leading,
                            endPoint: .trailing)
                    )
                )
                .foregroundStyle(.white)
        }
    }

    private func percentText(_ percent: Double, size: CGFloat) -> some View {
        Text("\(Int(percent.rounded()))%")
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText(value: percent))
            .foregroundStyle(Color.usage(percent: percent))
            .animation(Motion.gentle, value: percent)
    }

    private func tokenStat(_ title: String, _ tokens: Int64) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(Formatting.compactCount(tokens)).font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
    }
}
