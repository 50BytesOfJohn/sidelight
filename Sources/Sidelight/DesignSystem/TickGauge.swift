import SwiftUI

/// A dial of fine ticks around an empty center that light up clockwise from the top as `percent` grows, the
/// last one partly. Like ``SegmentedMeter``, a bright marker shows where the window's time has got to, so lit
/// ticks running past it mean the limit is going faster than the window.
///
/// Many thin ticks rather than a few thick rays: twelve rays of varying brightness read as a loading spinner.
///
/// With `showsRemaining`, the lit ticks are what's left of the limit and the marker what's left of the window's
/// time, as in ``SegmentedMeter``.
struct TickGauge: View {
    let percent: Double
    /// The share of the window's time that has passed, 0–1. No marker when `nil`.
    var elapsedFraction: Double?
    var diameter: CGFloat = 44
    var ticks = 36
    /// The empty center's share of the diameter.
    var innerFraction: CGFloat = 0.66
    var showsRemaining = false

    private var isHot: Bool { percent >= Color.usageWarningThreshold }

    var body: some View {
        let color = Color.usage(percent: percent)
        let shown = showsRemaining ? 100 - percent : percent
        let litTicks = min(max(shown / 100, 0), 1) * Double(ticks)
        let tickLength = diameter * (1 - innerFraction) / 2
        let tickWidth = max(1, diameter * 0.032)
        ZStack {
            ForEach(0..<ticks, id: \.self) { index in
                let lit = min(max(litTicks - Double(index), 0), 1)
                Capsule()
                    .fill(Color.primary.opacity(0.13))
                    .overlay(Capsule().fill(color).opacity(lit))
                    .frame(width: tickWidth, height: tickLength)
                    .offset(y: -(diameter - tickLength) / 2)
                    .rotationEffect(.degrees(360 * Double(index) / Double(ticks)))
            }
            .shadow(color: isHot ? color.opacity(0.6) : .clear, radius: isHot ? diameter * 0.05 : 0)
            if let elapsedFraction {
                // Reaches a little further in than the ticks, so it stays visible over a lit one.
                let markerLength = tickLength + diameter * 0.06
                Capsule()
                    .fill(Color.primary.opacity(0.9))
                    .frame(width: tickWidth * 1.4, height: markerLength)
                    .shadow(color: .black.opacity(0.35), radius: 1)
                    .offset(y: -(diameter - markerLength) / 2)
                    .rotationEffect(
                        .degrees(360 * min(max(showsRemaining ? 1 - elapsedFraction : elapsedFraction, 0), 1)))
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(Motion.gentle, value: percent)
        .accessibilityElement()
        .accessibilityValue("\(Int(shown.rounded())) percent\(showsRemaining ? " left" : "")")
    }
}
