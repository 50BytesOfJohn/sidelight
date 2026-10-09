import SwiftUI
import EventKit

enum CalendarWidget: PanelWidget {
    static let meta = WidgetMeta(kind: "calendar", title: "Next events", icon: "calendar", tint: .red,
                                 summary: "Upcoming events today and tomorrow (EventKit).")

    static func content(_ ctx: WidgetContext) -> some View { CalendarView(m: ctx.models.cal, ctx: ctx) }

    static func settings(_ s: Binding<WidgetSettings>) -> some View {
        Stepper("Events shown: \(s.wrappedValue.eventCount)", value: s.eventCount, in: 1...10)
    }
}

private struct CalendarView: View {
    @ObservedObject var m: CalendarModel
    let ctx: WidgetContext
    static let tf: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f }()

    var events: [EKEvent] { Array(m.events.prefix(ctx.settings.eventCount)) }

    var body: some View {
        if ctx.bar || ctx.size == .minimal { minimal }
        else if !m.authorized {
            VStack(alignment: .leading, spacing: 6) {
                Text("No calendar access").font(.system(size: ctx.size == .compact ? 11 : 13)).foregroundStyle(.secondary)
                Button(ctx.size == .compact ? "Grant" : "Grant calendar access") { m.requestAccess() }.buttonStyle(.glass).controlSize(ctx.size == .compact ? .small : .regular)
            }
        } else if events.isEmpty {
            Text(ctx.size == .compact ? "No events" : "Nothing today or tomorrow").font(.system(size: ctx.size == .compact ? 11 : 13)).foregroundStyle(.secondary)
        } else if ctx.size == .regular {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(events, id: \.eventIdentifier) { e in
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: e.calendar.color)).frame(width: 3, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title ?? "").font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(e.isAllDay ? "all day" : Self.tf.string(from: e.startDate)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(events, id: \.eventIdentifier) { e in
                    HStack(spacing: 6) {
                        Circle().fill(Color(nsColor: e.calendar.color)).frame(width: 6, height: 6)
                        Text(e.title ?? "").font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(e.isAllDay ? "day" : e.startDate.formatted(.dateTime.hour().minute())).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// minimal / bar: countdown to the next event with a color dot
    @ViewBuilder var minimal: some View {
        let next = m.events.first { !$0.isAllDay && $0.endDate > Date() }
        TimelineView(.everyMinute) { t in
            if !m.authorized {
                Image(systemName: "calendar.badge.exclamationmark").font(.system(size: 16)).foregroundStyle(.secondary)
                    .onTapGesture { m.requestAccess() }
            } else if let e = next {
                let color = Color(nsColor: e.calendar.color)
                let cd = Theme.shortCountdown(to: e.startDate, now: t.date)
                if ctx.bar {
                    HStack(spacing: 5) {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text(cd).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(e.title ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 110, alignment: .leading)
                    }
                    .help(e.title ?? "")
                } else {
                    VStack(spacing: 3) {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text(cd).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.7)
                    }
                    .help("\(e.title ?? "") · \(Self.tf.string(from: e.startDate))")
                }
            } else {
                Image(systemName: "calendar").font(.system(size: 16)).foregroundStyle(.tertiary)
            }
        }
    }
}
