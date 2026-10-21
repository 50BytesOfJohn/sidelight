import SidelightCore
import SwiftUI

/// A ring around the percentage, solid or in ticks, with the status and time left beside it.
struct RingBatteryFace: View {
    let reading: BatteryReading
    let settings: BatterySettings
    let layout: WidgetLayout
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        switch layout {
        case .regular:
            HStack(spacing: 12) {
                gauge(diameter: 44)
                VStack(alignment: .leading, spacing: 1) {
                    status(size: 13)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .compact:
            HStack(spacing: 8) {
                gauge(diameter: 32)
                VStack(alignment: .leading, spacing: 0) {
                    status(size: 11.5)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .minimal:
            VStack(spacing: 4) {
                gauge(diameter: 40)
                if let glance {
                    HStack(spacing: 2) {
                        ChargingBolt(reading: reading, size: 8)
                        Text(glance).font(.system(size: 10, weight: .medium).monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
        case .bar:
            HStack(spacing: 6) {
                ring(diameter: 17)
                HStack(spacing: 3) {
                    ChargingBolt(reading: reading, size: 9)
                    PercentText(percent: Double(reading.percent), size: 11.5)
                }
                if let glance {
                    Text(glance).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
    }

    private var color: Color { reading.tone.color }

    /// The ring with the percentage inside it.
    @ViewBuilder
    private func gauge(diameter: CGFloat) -> some View {
        switch settings.ring.gauge {
        case .ticks:
            PercentGauge(percent: Double(reading.percent), diameter: diameter, tint: color)
        case .solid:
            BatteryRing(percent: reading.percent, color: color, diameter: diameter, lineWidth: diameter * 0.09)
                .overlay {
                    Text("\(reading.percent)")
                        .font(.system(size: diameter * 0.3, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: diameter * 0.62)
                        .contentTransition(.numericText(value: Double(reading.percent)))
                        .animation(reducesMotion ? nil : Motion.gentle, value: reading.percent)
                }
        }
    }

    /// The ring alone, too small for a number.
    @ViewBuilder
    private func ring(diameter: CGFloat) -> some View {
        switch settings.ring.gauge {
        case .ticks:
            TickGauge(percent: Double(reading.percent), diameter: diameter, ticks: 24, innerFraction: 0.5, tint: color)
        case .solid:
            BatteryRing(percent: reading.percent, color: color, diameter: diameter, lineWidth: 2.5)
        }
    }

    private func status(size: CGFloat) -> some View {
        HStack(spacing: 3) {
            ChargingBolt(reading: reading, size: size * 0.8)
            Text(BatteryText.status(reading)).font(.system(size: size, weight: .semibold))
        }
    }

    private var subtitle: String? {
        BatteryText.subtitle(reading, showsTimeRemaining: settings.showsTimeRemaining, showsPower: settings.showsPower)
    }

    private var glance: String? {
        settings.showsTimeRemaining ? BatteryText.shortTimeRemaining(reading) : nil
    }
}

/// One continuous arc from the top, clockwise, as far as the charge.
struct BatteryRing: View {
    let percent: Int
    let color: Color
    let diameter: CGFloat
    let lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reducesMotion ? nil : Motion.gentle, value: percent)
        }
        .padding(lineWidth / 2)
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}
