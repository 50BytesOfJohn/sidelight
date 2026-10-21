import SidelightCore
import SwiftUI

/// The battery glyph with the percentage beside it, like the menu bar, and what else was asked for at the line's end.
struct GlyphBatteryFace: View {
    let reading: BatteryReading
    let settings: BatterySettings
    let layout: WidgetLayout

    private var options: GlyphBatteryOptions { settings.glyph }
    private var color: Color { reading.tone.color }

    var body: some View {
        switch layout {
        case .regular:
            HStack(spacing: 8) {
                glyph(width: 27, height: 13)
                if options.showsPercent { PercentText(percent: Double(reading.percent), size: 14) }
                Spacer(minLength: 6)
                Text(detail)
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        case .compact:
            HStack(spacing: 6) {
                glyph(width: 23, height: 11)
                if options.showsPercent { PercentText(percent: Double(reading.percent), size: 12.5) }
                Spacer(minLength: 4)
                Text(glance ?? BatteryText.status(reading))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        case .minimal:
            VStack(spacing: 4) {
                glyph(width: 30, height: 14)
                if options.showsPercent { PercentText(percent: Double(reading.percent), size: 12) }
                if let glance {
                    Text(glance).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
        case .bar:
            HStack(spacing: 5) {
                glyph(width: 23, height: 11)
                if options.showsPercent { PercentText(percent: Double(reading.percent), size: 11.5) }
                if let glance {
                    Text(glance).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
    }

    private func glyph(width: CGFloat, height: CGFloat) -> some View {
        BatteryCell(
            percent: reading.percent, color: color, width: width, height: height,
            showsBolt: reading.state == .charging)
    }

    /// `3h 12m left · 8.4 W`, or the status when there's no estimate.
    private var detail: String {
        BatteryText.detail(reading, showsTimeRemaining: settings.showsTimeRemaining, showsPower: settings.showsPower)
    }

    /// `3h 12m`, when the time left is shown and known.
    private var glance: String? {
        settings.showsTimeRemaining ? BatteryText.shortTimeRemaining(reading) : nil
    }
}
