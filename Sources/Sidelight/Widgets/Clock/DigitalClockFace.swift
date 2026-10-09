import SidelightCore
import SwiftUI

/// The original face: large rounded digits with the date underneath.
struct DigitalClockFace: View {
    let date: Date
    let reading: ClockReading
    let showsSeconds: Bool
    let layout: WidgetLayout

    var body: some View {
        content
            .monospacedDigit()
            .animation(Motion.snappy, value: reading.minuteOfDay)
    }

    private var minuteValue: Double { Double(reading.minuteOfDay) }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .regular:
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    time(size: 46, weight: .thin)
                    if showsSeconds {
                        Text(":" + reading.second)
                            .font(.system(size: 22, weight: .light, design: .rounded))
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: Double(reading.second) ?? 0))
                    }
                    period(size: 14)
                }
                Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        case .compact:
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    time(size: 30, weight: .light)
                    if showsSeconds {
                        Text(":" + reading.second)
                            .font(.system(size: 14, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    period(size: 10)
                }
                Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .minimal:
            // Hours over minutes, plus a tiny weekday initial.
            VStack(spacing: -3) {
                Text(reading.hour).font(.system(size: 21, weight: .semibold, design: .rounded))
                Text(reading.minute)
                    .font(.system(size: 21, weight: .light, design: .rounded))
                    .foregroundStyle(.secondary)
                if showsSeconds {
                    Text(reading.second)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
                }
                Text(date, format: .dateTime.weekday(.narrow))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .contentTransition(.numericText(value: minuteValue))
        case .bar:
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                time(size: 15, weight: .semibold)
                if showsSeconds {
                    Text(reading.second)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                if let period = reading.period {
                    Text(period).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                Text(date, format: .dateTime.weekday(.abbreviated).day())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func time(size: CGFloat, weight: Font.Weight) -> some View {
        Text("\(reading.hour):\(reading.minute)")
            .font(.system(size: size, weight: weight, design: .rounded))
            .contentTransition(.numericText(value: minuteValue))
    }

    @ViewBuilder
    private func period(size: CGFloat) -> some View {
        if let period = reading.period {
            Text(" " + period).font(.system(size: size, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}
