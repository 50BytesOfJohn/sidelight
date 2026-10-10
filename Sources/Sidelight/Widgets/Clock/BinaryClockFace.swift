import SidelightCore
import SwiftUI

/// Binary-coded decimal: a column of dots for each digit of the time, worth 8, 4, 2 and 1 from the top.
struct BinaryClockFace: View {
    let date: Date
    let reading: ClockReading
    let options: BinaryClockOptions
    let showsSeconds: Bool
    let layout: WidgetLayout
    let alignment: ClockAlignment

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(date, format: .dateTime.hour().minute().weekday(.wide).day().month(.wide)))
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .regular:
            VStack(alignment: alignment.horizontal, spacing: 10) {
                dotsAndPeriod(dot: 12, periodSize: 11)
                Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        case .compact:
            VStack(alignment: alignment.horizontal, spacing: 6) {
                dotsAndPeriod(dot: 9, periodSize: 9)
                Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .minimal:
            // Six columns of seconds need smaller dots to fit the narrow column.
            VStack(spacing: 5) {
                dots(dot: showsSeconds ? 5 : 8)
                Text(date, format: .dateTime.weekday(.narrow))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
        case .bar:
            HStack(spacing: 6) {
                dots(dot: 4.5)
                if options.showsDigits {
                    Text("\(reading.hour):\(reading.minute)\(reading.period.map { " " + $0 } ?? "")")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                Text(date, format: .dateTime.weekday(.abbreviated).day())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dotsAndPeriod(dot: CGFloat, periodSize: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: dot * 0.8) {
            dots(dot: dot)
            if let period = reading.period {
                Text(period)
                    .font(.system(size: periodSize, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dots(dot: CGFloat) -> some View {
        BinaryDots(
            reading: BinaryClockReading(reading: reading, includesSeconds: showsSeconds), dot: dot,
            showsDigits: options.showsDigits
        )
        .foregroundStyle(options.color.style)
    }
}

/// The columns drawn in one canvas pass in the current foreground style: lit dots solid, unlit ones faint.
private struct BinaryDots: View {
    let reading: BinaryClockReading
    let dot: CGFloat
    /// Digits under the columns, where they'd be large enough to read.
    let showsDigits: Bool

    private var gap: CGFloat { dot * 0.4 }
    private var groupGap: CGFloat { dot * 1.1 }
    private var gridHeight: CGFloat { CGFloat(BinaryClockReading.rows) * (dot + gap) - gap }
    private var digitSize: CGFloat { dot * 0.95 }
    private var drawsDigits: Bool { showsDigits && digitSize >= 7 }

    var body: some View {
        let columns = reading.groups.reduce(0) { $0 + $1.count }
        let width =
            CGFloat(columns) * dot + CGFloat(columns - reading.groups.count) * gap
            + CGFloat(reading.groups.count - 1) * groupGap
        Canvas { context, _ in
            var x: CGFloat = 0
            for (index, group) in reading.groups.enumerated() {
                if index > 0 { x += groupGap - gap }
                for column in group {
                    draw(column, at: x, in: &context)
                    x += dot + gap
                }
            }
        }
        .frame(width: width, height: gridHeight + (drawsDigits ? digitSize * 1.6 : 0))
        .accessibilityHidden(true)
    }

    private func draw(_ column: BinaryClockReading.Column, at x: CGFloat, in context: inout GraphicsContext) {
        for bit in 0..<column.bits {
            let y = CGFloat(BinaryClockReading.rows - 1 - bit) * (dot + gap)
            let circle = Path(ellipseIn: CGRect(x: x, y: y, width: dot, height: dot))
            context.fill(circle, with: column.isLit(bit) ? .foreground : .style(.foreground.opacity(0.14)))
        }
        if drawsDigits {
            let digit = Text("\(column.digit)")
                .font(.system(size: digitSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
            var label = context
            label.opacity = 0.6
            label.draw(digit, at: CGPoint(x: x + dot / 2, y: gridHeight + digitSize * 0.95), anchor: .center)
        }
    }
}
