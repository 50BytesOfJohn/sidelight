import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let calendar = WidgetMetadata(
        title: "Next events",
        systemImage: "calendar",
        tint: .red,
        summary: "Upcoming events today and tomorrow (EventKit)."
    )
}

extension CalendarSettings {
    var summary: String { eventCount == 1 ? "1 event" : "\(eventCount) events" }
}

struct CalendarSettingsEditor: View {
    @Binding var settings: CalendarSettings

    var body: some View {
        Stepper(
            "Events shown: \(settings.eventCount)", value: $settings.eventCount, in: CalendarSettings.eventCountRange)
    }
}

struct CalendarWidgetView: View {
    let settings: CalendarSettings
    let layout: WidgetLayout
    @Environment(CalendarService.self) private var calendar

    private var events: ArraySlice<CalendarEvent> { calendar.upcomingEvents.prefix(settings.eventCount) }

    var body: some View {
        if layout.isGlanceable {
            NextEventCountdown(layout: layout)
        } else if calendar.access != .granted {
            VStack(alignment: .leading, spacing: 6) {
                Text("No calendar access")
                    .font(.system(size: layout == .compact ? 11 : 13))
                    .foregroundStyle(.secondary)
                Button(layout == .compact ? "Grant" : "Grant calendar access") {
                    Task { await calendar.requestAccess() }
                }
                .buttonStyle(.glass)
                .controlSize(layout == .compact ? .small : .regular)
            }
        } else if events.isEmpty {
            Text(layout == .compact ? "No events" : "Nothing today or tomorrow")
                .font(.system(size: layout == .compact ? 11 : 13))
                .foregroundStyle(.secondary)
        } else if layout == .regular {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(events) { event in
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 3, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Group {
                                if event.isAllDay {
                                    Text("all day")
                                } else {
                                    Text(event.startDate, format: .dateTime.weekday(.abbreviated).hour().minute())
                                }
                            }
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(events) { event in
                    HStack(spacing: 6) {
                        Circle().fill(event.color).frame(width: 6, height: 6)
                        Text(event.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 2)
                        Group {
                            if event.isAllDay {
                                Text("day")
                            } else {
                                Text(event.startDate, format: .dateTime.hour().minute())
                            }
                        }
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Minimal and bar layouts: a countdown to the next timed event with its calendar color.
private struct NextEventCountdown: View {
    let layout: WidgetLayout
    @Environment(CalendarService.self) private var calendar

    var body: some View {
        TimelineView(.everyMinute) { context in
            if calendar.access != .granted {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .onTapGesture { Task { await calendar.requestAccess() } }
            } else if let event = calendar.nextTimedEvent(after: context.date) {
                let countdown = Formatting.shortCountdown(to: event.startDate, now: context.date)
                if layout == .bar {
                    HStack(spacing: 5) {
                        Circle().fill(event.color).frame(width: 7, height: 7)
                        Text(countdown).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(event.title)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 110, alignment: .leading)
                    }
                    .help(event.title)
                } else {
                    VStack(spacing: 3) {
                        Circle().fill(event.color).frame(width: 7, height: 7)
                        Text(countdown)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.7)
                    }
                    .help(
                        "\(event.title) · \(event.startDate.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
                    )
                }
            } else {
                Image(systemName: "calendar").font(.system(size: 16)).foregroundStyle(.tertiary)
            }
        }
    }
}
