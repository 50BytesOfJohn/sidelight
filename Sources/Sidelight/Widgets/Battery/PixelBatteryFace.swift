import SidelightCore
import SwiftUI

/// Dot-matrix digits beside a cell of segments, in a phosphor color, like an old LCD or LED display.
struct PixelBatteryFace: View {
    let reading: BatteryReading
    let settings: BatterySettings
    let layout: WidgetLayout

    private var options: PixelBatteryOptions { settings.pixel }

    var body: some View {
        content
            .foregroundStyle(style)
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .regular:
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 12) {
                    pixels(BatteryText.percent(reading), size: 5)
                    cell(size: 3)
                }
                detail(size: 2).opacity(0.65)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .compact:
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .bottom, spacing: 8) {
                    pixels(BatteryText.percent(reading), size: 3.5)
                    cell(size: 2)
                }
                detail(size: 1.5).opacity(0.65)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .minimal:
            VStack(spacing: 5) {
                pixels(BatteryText.percent(reading), size: 2)
                cell(size: 1.5)
                if let time { pixels(time, size: 1).opacity(0.6) }
            }
            .frame(maxWidth: .infinity)
        case .bar:
            HStack(alignment: .center, spacing: 6) {
                pixels(BatteryText.percent(reading), size: 2)
                cell(size: 1.5)
                if let time { pixels(time, size: 1.5).opacity(0.65) }
            }
        }
    }

    /// The chosen color, unless the battery's state has its own.
    private var style: AnyShapeStyle {
        reading.tone == .normal ? options.color.style : AnyShapeStyle(reading.tone.color)
    }

    /// `3:12`, when the time left is shown and known.
    private var time: String? {
        settings.showsTimeRemaining ? BatteryText.clockTimeRemaining(reading) : nil
    }

    /// The status, time left and watts, dropping from the end what doesn't fit.
    private func detail(size: CGFloat) -> some View {
        let status = BatteryText.status(reading)
        let power = settings.showsPower ? reading.watts.map(BatteryText.power) : nil
        let full = [status, time, power, reading.isLowPowerMode ? "Low Power" : nil].compactMap(\.self)
        return ViewThatFits(in: .horizontal) {
            pixels(full.joined(separator: "  "), size: size)
            pixels([status, time].compactMap(\.self).joined(separator: "  "), size: size)
            pixels(status, size: size)
        }
    }

    private func pixels(_ text: String, size: CGFloat) -> some View {
        PixelText(text, pixelSize: size, showsUnlitPixels: options.showsUnlitPixels, glows: options.glows)
    }

    private func cell(size: CGFloat) -> some View {
        PixelText(
            line: .batteryCell(percent: reading.percent), pixelSize: size, showsUnlitPixels: options.showsUnlitPixels,
            glows: options.glows)
    }
}
