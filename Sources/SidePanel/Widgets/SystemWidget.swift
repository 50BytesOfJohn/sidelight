import SwiftUI

enum SystemWidget: PanelWidget {
    static let meta = WidgetMeta(kind: "system", title: "System", icon: "cpu", tint: .teal,
                                 summary: "CPU % and memory, refreshed every 2 s.")

    static func content(_ ctx: WidgetContext) -> some View { SystemView(m: ctx.models.stats, ctx: ctx) }

    static func settings(_ s: Binding<WidgetSettings>) -> some View {
        Picker("Show", selection: s.stats) {
            Text("CPU + memory").tag(StatsChoice.both)
            Text("CPU").tag(StatsChoice.cpu)
            Text("Memory").tag(StatsChoice.memory)
        }
    }
}

// NOTE: periodic data → no transitions. Animating a 2 s ticker kept SwiftUI permanently mid-animation
// (12–16 % CPU idle, see RESULTS round 2).
private struct SystemView: View {
    @ObservedObject var m: StatsModel
    let ctx: WidgetContext
    var cpu: Bool { ctx.settings.stats != .memory }
    var mem: Bool { ctx.settings.stats != .cpu }
    var memPct: Double { m.memUsedGB / m.memTotalGB * 100 }

    var body: some View {
        if ctx.bar {
            HStack(spacing: 6) {
                if cpu { VBar(pct: m.cpu, width: 5, height: 22); Text(String(format: "%.0f%%", m.cpu)).font(.system(size: 11.5, weight: .medium, design: .rounded)).monospacedDigit() }
                if mem { VBar(pct: memPct, width: 5, height: 22); Text(String(format: "%.0fG", m.memUsedGB)).font(.system(size: 11.5, weight: .medium, design: .rounded)).monospacedDigit() }
            }
        } else {
            switch ctx.size {
            case .regular:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 18) {
                        if cpu { metric("CPU", String(format: "%.0f", m.cpu), "%", frac: m.cpu / 100) }
                        if mem { metric("Memory", String(format: "%.1f", m.memUsedGB), "/ \(Int(m.memTotalGB)) GB", frac: m.memUsedGB / m.memTotalGB) }
                    }
                    Text(String(format: "panel RSS %.0f MB", m.selfRSSMB)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
            case .compact:
                VStack(alignment: .leading, spacing: 5) {
                    if cpu { row("CPU", String(format: "%.0f%%", m.cpu), m.cpu) }
                    if mem { row("MEM", String(format: "%.1f GB", m.memUsedGB), memPct) }
                }
            case .minimal:
                // two tiny vertical bars
                HStack(spacing: 7) {
                    if cpu { VStack(spacing: 3) { VBar(pct: m.cpu); Text("C").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary) } }
                    if mem { VStack(spacing: 3) { VBar(pct: memPct); Text("M").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary) } }
                }
                .help(String(format: "CPU %.0f%% · Memory %.1f GB", m.cpu, m.memUsedGB))
            }
        }
    }

    func metric(_ k: String, _ v: String, _ unit: String, frac: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(k).font(.system(size: 10.5)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(v).font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            UsageBar(pct: frac * 100, animated: false).frame(width: 110)
        }
    }
    func row(_ k: String, _ v: String, _ pct: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(k).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(v).font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
            }
            UsageBar(pct: pct, animated: false, height: 4)
        }
    }
}
