import SwiftUI

/// A whole-number percentage in rounded semibold digits that roll as the value changes.
struct PercentText: View {
    let percent: Double
    let size: CGFloat

    var body: some View {
        Text("\(Int(percent.rounded()))%")
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText(value: percent))
            .animation(Motion.gentle, value: percent)
    }
}

/// A ``TickGauge`` with its percentage as a bare number in the empty center.
struct PercentGauge: View {
    let percent: Double
    /// The number inside, when it isn't the gauge's own `percent`: what's left of a limit, say.
    var shown: Double?
    /// Shows a dash instead of the number: the window has reset, and its new usage isn't known.
    var isReset = false
    var elapsedFraction: Double?
    var diameter: CGFloat = 44
    var showsRemaining = false
    var labelWidth: CGFloat = 24
    /// The number's color; the primary one when `nil`.
    var labelColor: Color?
    /// The ticks' color, when it isn't the usage color (see ``TickGauge/tint``).
    var tint: Color?

    var body: some View {
        let shown = shown ?? percent
        TickGauge(
            percent: percent, elapsedFraction: elapsedFraction, diameter: diameter, showsRemaining: showsRemaining,
            tint: tint
        )
        .overlay {
            Text(isReset ? "–" : "\(Int(shown.rounded()))")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: labelWidth)
                .foregroundStyle(labelColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                .contentTransition(.numericText(value: shown))
                .animation(Motion.gentle, value: shown)
        }
    }
}
