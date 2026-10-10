import SidelightCore
import SwiftUI

/// A dial with hands, and the date beside it.
struct AnalogClockFace: View {
    let date: Date
    let options: AnalogClockOptions
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
            beside(dial(diameter: 96), spacing: 16) {
                Text(date, format: .dateTime.weekday(.wide))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(date, format: .dateTime.day().month(.wide))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        case .compact:
            beside(dial(diameter: 58), spacing: 10) {
                Text(date, format: .dateTime.weekday(.abbreviated))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(date, format: .dateTime.day().month(.abbreviated))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .minimal:
            VStack(spacing: 5) {
                dial(diameter: 46)
                if options.showsDate {
                    Text(date, format: .dateTime.weekday(.narrow))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
        case .bar:
            HStack(spacing: 6) {
                dial(diameter: 24)
                if options.showsDate {
                    Text(date, format: .dateTime.weekday(.abbreviated).day())
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The dial with the date on its far side from the card's edge: right-aligned clocks mirror, so the dial
    /// always sits against the edge it's aligned to and the date lines up toward it.
    private func beside(
        _ dial: some View, spacing: CGFloat, @ViewBuilder date: () -> some View
    ) -> some View {
        let isMirrored = alignment == .trailing
        let date = VStack(alignment: isMirrored ? .trailing : .leading, spacing: layout == .regular ? 2 : 1) { date() }
        return HStack(spacing: spacing) {
            if options.showsDate && isMirrored { date }
            dial
            if options.showsDate && !isMirrored { date }
        }
    }

    private func dial(diameter: CGFloat) -> some View {
        AnalogDial(hands: ClockHands(date: date), dial: options.dial, showsSeconds: showsSeconds)
            .frame(width: diameter, height: diameter)
    }
}

/// The face itself, drawn in one canvas pass in the current foreground style. It redraws only when the time it
/// shows changes, so a canvas costs less than a stack of shapes.
private struct AnalogDial: View {
    let hands: ClockHands
    let dial: AnalogClockOptions.Dial
    let showsSeconds: Bool

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            context.translateBy(x: center.x, y: center.y)

            let bounds = CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius)
            context.fill(Path(ellipseIn: bounds), with: .style(.foreground.opacity(0.06)))
            context.stroke(
                Path(ellipseIn: bounds.insetBy(dx: 0.5, dy: 0.5)), with: .style(.foreground.opacity(0.14)),
                lineWidth: 1)

            drawMarks(in: &context, radius: radius)

            hand(in: &context, turn: hands.hour, length: radius * 0.5, width: max(2, radius * 0.08))
            hand(in: &context, turn: hands.minute, length: radius * 0.78, width: max(1.5, radius * 0.05))
            if showsSeconds {
                hand(
                    in: &context, turn: hands.second, length: radius * 0.86, tail: radius * 0.16,
                    width: max(0.75, radius * 0.018), shading: .color(.orange))
            }
            let cap = max(1.5, radius * 0.07)
            context.fill(
                Path(ellipseIn: CGRect(x: -cap, y: -cap, width: 2 * cap, height: 2 * cap)),
                with: showsSeconds ? .color(.orange) : .foreground)
        }
    }

    private func drawMarks(in context: inout GraphicsContext, radius: CGFloat) {
        switch dial {
        case .ticks:
            // Minute ticks only where there's room for 60 of them.
            let showsMinutes = radius >= 30
            for index in 0..<60 where showsMinutes || index % 5 == 0 {
                let isHour = index % 5 == 0
                let length = radius * (isHour ? 0.14 : 0.06)
                tick(
                    in: &context, turn: Double(index) / 60, from: radius * 0.9 - length, to: radius * 0.9,
                    width: isHour ? max(1, radius * 0.035) : 0.75, opacity: isHour ? 0.75 : 0.3)
            }
        case .numerals:
            let fontSize = radius * 0.2
            let numerals = radius >= 30 ? Array(1...12) : [12, 3, 6, 9]
            for numeral in numerals {
                let angle = Angle.degrees(Double(numeral) * 30 - 90)
                let point = CGPoint(x: cos(angle.radians) * radius * 0.74, y: sin(angle.radians) * radius * 0.74)
                let text = Text("\(numeral)").font(.system(size: fontSize, weight: .medium, design: .rounded))
                context.draw(text, at: point, anchor: .center)
            }
        case .minimal:
            for quarter in 0..<4 {
                tick(
                    in: &context, turn: Double(quarter) / 4, from: radius * 0.74, to: radius * 0.88,
                    width: max(1.5, radius * 0.05), opacity: 0.6)
            }
        }
    }

    private func tick(
        in context: inout GraphicsContext, turn: Double, from inner: CGFloat, to outer: CGFloat, width: CGFloat,
        opacity: Double
    ) {
        var path = Path()
        path.move(to: point(turn: turn, distance: inner))
        path.addLine(to: point(turn: turn, distance: outer))
        context.stroke(
            path, with: .style(.foreground.opacity(opacity)), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    private func hand(
        in context: inout GraphicsContext, turn: Double, length: CGFloat, tail: CGFloat = 0, width: CGFloat,
        shading: GraphicsContext.Shading = .foreground
    ) {
        var path = Path()
        path.move(to: point(turn: turn, distance: -tail))
        path.addLine(to: point(turn: turn, distance: length))
        context.stroke(path, with: shading, style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    /// `distance` from the center toward `turn` of a full circle, clockwise from 12.
    private func point(turn: Double, distance: CGFloat) -> CGPoint {
        let angle = turn * 2 * .pi - .pi / 2
        return CGPoint(x: cos(angle) * distance, y: sin(angle) * distance)
    }
}
