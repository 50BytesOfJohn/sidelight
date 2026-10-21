import SidelightCore
import SwiftUI

/// A large battery cell filled to the charge, glossy or flat, with the percentage over it.
struct CellBatteryFace: View {
    let reading: BatteryReading
    let settings: BatterySettings
    let layout: WidgetLayout

    var body: some View {
        switch layout {
        case .regular:
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    PercentText(percent: Double(reading.percent), size: 22)
                    Spacer(minLength: 6)
                    HStack(spacing: 3) {
                        ChargingBolt(reading: reading, size: 10)
                        Text(BatteryText.status(reading)).font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                cell(height: 26)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        case .compact:
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    PercentText(percent: Double(reading.percent), size: 15)
                    Spacer(minLength: 4)
                    Text(glance ?? BatteryText.status(reading))
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                cell(height: 17)
            }
            .lineLimit(1)
        case .minimal:
            VStack(spacing: 5) {
                cell(height: 18).padding(.horizontal, 4)
                PercentText(percent: Double(reading.percent), size: 12)
                if let glance {
                    Text(glance).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
        case .bar:
            HStack(spacing: 6) {
                cell(width: 34, height: 15)
                PercentText(percent: Double(reading.percent), size: 11.5)
                if let glance {
                    Text(glance).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
    }

    private func cell(width: CGFloat? = nil, height: CGFloat) -> some View {
        BatteryCell(
            percent: reading.percent, color: reading.tone.color, width: width, height: height,
            finish: settings.cell.finish, showsBolt: reading.state == .charging)
    }

    private var subtitle: String? {
        BatteryText.subtitle(reading, showsTimeRemaining: settings.showsTimeRemaining, showsPower: settings.showsPower)
    }

    private var glance: String? {
        settings.showsTimeRemaining ? BatteryText.shortTimeRemaining(reading) : nil
    }
}
