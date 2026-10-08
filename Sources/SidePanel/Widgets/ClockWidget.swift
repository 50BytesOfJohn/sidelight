import SwiftUI

enum ClockWidget: PanelWidget {
    static let meta = WidgetMeta(kind: "clock", title: "Clock", icon: "clock", tint: .blue,
                                 summary: "Time and date. Seconds and 12/24 h optional.")

    static func content(_ ctx: WidgetContext) -> some View { ClockView(ctx: ctx) }

    static func settings(_ s: Binding<WidgetSettings>) -> some View {
        Toggle("Show seconds", isOn: s.showSeconds)
        Toggle("24-hour time", isOn: s.use24h)
    }
}

private struct ClockView: View {
    let ctx: WidgetContext
    var body: some View {
        // Ticks once a minute unless seconds are on — the per-second variant is measurable energy.
        if ctx.settings.showSeconds {
            TimelineView(.periodic(from: .now, by: 1)) { t in ClockFace(date: t.date, ctx: ctx) }
        } else {
            TimelineView(.everyMinute) { t in ClockFace(date: t.date, ctx: ctx) }
        }
    }
}

private struct ClockFace: View {
    let date: Date
    let ctx: WidgetContext

    var body: some View {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let h24 = c.hour ?? 0, m = c.minute ?? 0, s = c.second ?? 0
        let h = ctx.settings.use24h ? h24 : (h24 % 12 == 0 ? 12 : h24 % 12)
        let hh = ctx.settings.use24h ? String(format: "%02d", h) : "\(h)"
        let mm = String(format: "%02d", m)
        let ampm = ctx.settings.use24h ? nil : (h24 < 12 ? "AM" : "PM")
        let minuteValue = Double(h24 * 60 + m)

        Group {
            if ctx.bar {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(hh):\(mm)").font(.system(size: 15, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText(value: minuteValue))
                    if ctx.settings.showSeconds { Text(String(format: "%02d", s)).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary) }
                    if let ampm { Text(ampm).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
                    Text(date, format: .dateTime.weekday(.abbreviated).day()).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                switch ctx.size {
                case .regular:
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text("\(hh):\(mm)").font(.system(size: 46, weight: .thin, design: .rounded))
                                .contentTransition(.numericText(value: minuteValue))
                            if ctx.settings.showSeconds {
                                Text(String(format: ":%02d", s)).font(.system(size: 22, weight: .light, design: .rounded)).foregroundStyle(.secondary)
                                    .contentTransition(.numericText(value: Double(s)))
                            }
                            if let ampm { Text(" " + ampm).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary) }
                        }
                        Text(date, format: .dateTime.weekday(.wide).day().month(.wide)).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    }
                case .compact:
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text("\(hh):\(mm)").font(.system(size: 30, weight: .light, design: .rounded))
                                .contentTransition(.numericText(value: minuteValue))
                            if ctx.settings.showSeconds { Text(String(format: ":%02d", s)).font(.system(size: 14, design: .rounded)).foregroundStyle(.secondary) }
                            if let ampm { Text(" " + ampm).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary) }
                        }
                        Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                case .minimal:
                    // HH over MM, stacked, plus a tiny weekday initial
                    VStack(spacing: -3) {
                        Text(hh).font(.system(size: 21, weight: .semibold, design: .rounded))
                        Text(mm).font(.system(size: 21, weight: .light, design: .rounded)).foregroundStyle(.secondary)
                        if ctx.settings.showSeconds { Text(String(format: "%02d", s)).font(.system(size: 9, design: .rounded)).foregroundStyle(.tertiary).padding(.top, 3) }
                        Text(date, format: .dateTime.weekday(.narrow)).font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary).padding(.top, 4)
                    }
                    .contentTransition(.numericText(value: minuteValue))
                }
            }
        }
        .monospacedDigit()
        .animation(Theme.snappy, value: minuteValue)
    }
}
