import SwiftUI

/// Circular usage gauge with an optional thinner concentric ring (e.g. the weekly limit inside the 5-hour one).
struct UsageRing: View {
    let percent: Double
    var innerPercent: Double?
    var diameter: CGFloat = 86
    var lineWidth: CGFloat = 9
    var showsLabel = true
    var caption: String? = "% · 5h"
    var fontSize: CGFloat = 24

    private var isHot: Bool { percent >= Color.usageWarningThreshold }

    var body: some View {
        let color = Color.usage(percent: percent)
        ZStack {
            Circle().stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, percent / 100))
                .stroke(
                    AngularGradient(
                        colors: [color.opacity(0.55), color],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(max(1, 360 * percent / 100))
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: isHot ? color.opacity(0.75) : .clear, radius: isHot ? lineWidth * 0.75 : 0)
            if let innerPercent {
                innerRing(innerPercent)
            }
            if showsLabel {
                label
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(Motion.gentle, value: percent)
        .animation(Motion.gentle, value: innerPercent)
        .phaseAnimator(isHot ? [1.0, 1.05, 1.0] : [1.0], trigger: percent) { content, scale in
            content.scaleEffect(scale)
        } animation: { _ in
            Motion.pulse
        }
    }

    private func innerRing(_ percent: Double) -> some View {
        let width = max(2, lineWidth * 0.45)
        let ringDiameter = diameter - lineWidth * 2 - max(3, lineWidth * 0.5) * 2
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: width)
            Circle()
                .trim(from: 0, to: max(0.001, percent / 100))
                .stroke(Color.usage(percent: percent), style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: ringDiameter, height: ringDiameter)
    }

    private var label: some View {
        VStack(spacing: -1) {
            Text("\(Int(percent.rounded()))")
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: percent))
            if let caption {
                Text(caption)
                    .font(.system(size: max(7, fontSize * 0.38), weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
