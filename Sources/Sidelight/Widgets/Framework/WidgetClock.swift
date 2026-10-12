import SwiftUI

/// Draws `content` at the current time, again at the start of every minute (or second): countdowns, ages and
/// clock faces move on with it.
///
/// Catalogs that set ``EnvironmentValues/frozenDate`` get that instant and no redraws, and a panel hidden with the
/// shortcut, or on a sleeping or locked screen, stops redrawing until it can be seen again, so nothing ticks where
/// nobody can see it.
struct WidgetClock<Content: View>: View {
    enum Tick {
        case minute
        case second
    }

    var tick = Tick.minute
    @ViewBuilder var content: (Date) -> Content

    @Environment(\.frozenDate) private var frozenDate
    @Environment(\.isPanelShown) private var isPanelShown

    var body: some View {
        let interval: TimeInterval? =
            if frozenDate != nil || !isPanelShown { nil } else { tick == .second ? 1 : 60 }
        TimelineView(AlignedSchedule(interval: interval)) { context in
            content(frozenDate ?? context.date)
        }
    }
}

/// Now, then every whole `interval` on the wall clock; only now while `interval` is `nil`.
private struct AlignedSchedule: TimelineSchedule {
    let interval: TimeInterval?

    func entries(from start: Date, mode: TimelineScheduleMode) -> UnfoldFirstSequence<Date> {
        sequence(first: start) { [interval] date in
            interval.map { interval in
                let elapsed = date.timeIntervalSinceReferenceDate
                return Date(timeIntervalSinceReferenceDate: ((elapsed / interval).rounded(.down) + 1) * interval)
            }
        }
    }
}
