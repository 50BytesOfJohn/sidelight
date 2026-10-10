import SwiftUI

/// Usage meter for a time window, in one segment per unit of its time (five for five hours, seven for a week),
/// with a tick where the window's time has got to. Fill past the tick means the limit is going faster than the
/// window and runs out before it resets.
struct SegmentedMeter: View {
    let percent: Double
    let segments: Int
    /// The share of the window's time that has passed, 0–1. No tick when `nil`.
    var elapsedFraction: Double?
    var height: CGFloat = 6
    var spacing: CGFloat = 3

    var body: some View {
        let color = Color.usage(percent: percent)
        let filledSegments = min(max(percent / 100, 0), 1) * Double(segments)
        GeometryReader { proxy in
            let segmentWidth = (proxy.size.width - spacing * CGFloat(segments - 1)) / CGFloat(segments)
            HStack(spacing: spacing) {
                ForEach(0..<segments, id: \.self) { index in
                    let fill = min(max(filledSegments - Double(index), 0), 1)
                    Capsule()
                        .fill(Color.primary.opacity(0.10))
                        .overlay(alignment: .leading) {
                            Rectangle().fill(color).frame(width: segmentWidth * fill)
                        }
                        .clipShape(.capsule)
                }
            }
            if let elapsedFraction {
                tick
                    .position(
                        x: tickPosition(elapsedFraction, segmentWidth: segmentWidth),
                        y: proxy.size.height / 2
                    )
            }
        }
        .frame(height: height)
        .animation(Motion.gentle, value: percent)
        .accessibilityElement()
        .accessibilityValue("\(Int(percent.rounded())) percent")
    }

    private var tick: some View {
        Capsule()
            .fill(Color.primary.opacity(0.9))
            .frame(width: 2, height: height + 6)
            .shadow(color: .black.opacity(0.35), radius: 1)
    }

    /// Where `fraction` of the window's time falls, skipping the gaps between segments.
    private func tickPosition(_ fraction: Double, segmentWidth: CGFloat) -> CGFloat {
        let position = min(max(fraction, 0), 1) * Double(segments)
        let segment = min(Int(position), segments - 1)
        return CGFloat(segment) * (segmentWidth + spacing) + segmentWidth * CGFloat(position - Double(segment))
    }
}
