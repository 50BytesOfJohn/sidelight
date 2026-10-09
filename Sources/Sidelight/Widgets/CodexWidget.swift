import SwiftUI

enum CodexWidget: PanelWidget {
    static let meta = WidgetMeta(kind: "codex", title: "Codex", icon: "chart.pie", tint: .orange,
                                 summary: "Codex 5-hour and weekly rate limits, resets, tokens.")

    static func content(_ ctx: WidgetContext) -> some View { CodexView(m: ctx.models.codex, ctx: ctx) }

    static func settings(_ s: Binding<WidgetSettings>) -> some View {
        Toggle("Show weekly limit", isOn: s.showWeekly)
    }
}

private struct CodexView: View {
    @ObservedObject var m: CodexModel
    let ctx: WidgetContext

    var body: some View {
        if let five = m.fiveHour {
            let weekly = ctx.settings.showWeekly ? m.weekly : nil
            if ctx.bar { bar(five, weekly) }
            else {
                switch ctx.size {
                case .regular: regular(five, weekly)
                case .compact: compact(five, weekly)
                case .minimal: minimal(five, weekly)
                }
            }
        } else {
            placeholder
        }
    }

    @ViewBuilder var placeholder: some View {
        if ctx.size == .minimal || ctx.bar {
            Image(systemName: m.source == "unavailable" ? "exclamationmark.circle" : "hourglass").foregroundStyle(.secondary)
        } else {
            Text(m.source == "unavailable" ? "No Codex data" : "Loading Codex usage…").font(.callout).foregroundStyle(.secondary)
        }
    }

    // regular: big ring + plan/credits/countdown, weekly bar, tokens + sparkline
    func regular(_ five: CodexModel.Window, _ weekly: CodexModel.Window?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                UsageRing(pct: five.usedPercent)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        planBadge
                        if let rc = m.resetCredits, rc > 0 {
                            Label("\(rc)", systemImage: "arrow.counterclockwise.circle.fill")
                                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                .contentTransition(.numericText(value: Double(rc))).foregroundStyle(.secondary)
                                .help("\(rc) rate-limit reset credits available")
                        }
                    }
                    TimelineView(.everyMinute) { t in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("5h resets in").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            Text(Theme.countdown(to: five.resetsAt, now: t.date))
                                .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if let wk = weekly {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Weekly").font(.system(size: 11.5, weight: .medium))
                        pctText(wk.usedPercent, size: 11.5)
                        Spacer()
                        TimelineView(.everyMinute) { t in
                            Text("resets in \(Theme.countdown(to: wk.resetsAt, now: t.date))").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    UsageBar(pct: wk.usedPercent)
                }
            }
            if m.lifetimeTokens != nil || m.sessionTokens != nil {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 1) {
                        if let t = m.todayTokens { stat("Today", Theme.compact(t)) }
                        if let l = m.lifetimeTokens { stat("Lifetime", Theme.compact(l)) }
                        if let st = m.sessionTokens, m.source == "rollout file" { stat("Session", Theme.compact(st)) }
                    }
                    Spacer()
                    if !m.daily.isEmpty { Sparkline(values: m.daily).frame(width: 120) }
                }
            }
            HStack { Spacer(); Text(m.source).font(.system(size: 8.5, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary) }
        }
    }

    // compact: mid ring, countdown, thin weekly bar
    func compact(_ five: CodexModel.Window, _ weekly: CodexModel.Window?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                UsageRing(pct: five.usedPercent, diameter: 54, line: 6, caption: "5h", fontSize: 16)
                VStack(alignment: .leading, spacing: 3) {
                    planBadge
                    TimelineView(.everyMinute) { t in
                        Text(Theme.countdown(to: five.resetsAt, now: t.date))
                            .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    Text("until reset").font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let wk = weekly {
                HStack(spacing: 6) {
                    Text("Wk").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    UsageBar(pct: wk.usedPercent, height: 5)
                    pctText(wk.usedPercent, size: 10)
                }
            }
        }
    }

    // minimal: small ring with % inside; weekly as a thin inner ring
    func minimal(_ five: CodexModel.Window, _ weekly: CodexModel.Window?) -> some View {
        VStack(spacing: 4) {
            UsageRing(pct: five.usedPercent, inner: weekly?.usedPercent, diameter: 46, line: 5, caption: nil, fontSize: 13)
            TimelineView(.everyMinute) { t in
                Text(Theme.countdown(to: five.resetsAt, now: t.date).components(separatedBy: " ").first ?? "")
                    .font(.system(size: 9, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    // bar: tiny ring + % + weekly dot
    func bar(_ five: CodexModel.Window, _ weekly: CodexModel.Window?) -> some View {
        HStack(spacing: 6) {
            UsageRing(pct: five.usedPercent, inner: weekly?.usedPercent, diameter: 24, line: 3.5, label: false)
            pctText(five.usedPercent, size: 13)
            if let wk = weekly {
                Circle().fill(Theme.usage(wk.usedPercent)).frame(width: 6, height: 6)
                Text("\(Int(wk.usedPercent.rounded()))%").font(.system(size: 10.5, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .animation(Theme.spring, value: five.usedPercent)
    }

    @ViewBuilder var planBadge: some View {
        if let plan = m.plan {
            Text(plan.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.8)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(LinearGradient(colors: [.purple.opacity(0.85), .blue.opacity(0.85)], startPoint: .leading, endPoint: .trailing)))
                .foregroundStyle(.white)
        }
    }
    func pctText(_ v: Double, size: CGFloat) -> some View {
        Text("\(Int(v.rounded()))%").font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
            .contentTransition(.numericText(value: v)).foregroundStyle(Theme.usage(v))
            .animation(Theme.spring, value: v)
    }
    func stat(_ k: String, _ v: String) -> some View {
        HStack(spacing: 4) {
            Text(k).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(v).font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
    }
}
