import SidelightCore
import SwiftUI

/// Dot-matrix digits in a phosphor color, like an old LCD or LED display.
struct PixelClockFace: View {
    let date: Date
    let reading: ClockReading
    let options: PixelClockOptions
    let showsSeconds: Bool
    let layout: WidgetLayout

    var body: some View {
        content
            .foregroundStyle(options.color.color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(date, format: .dateTime.hour().minute().weekday(.wide).day().month(.wide)))
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .regular:
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 6) {
                    pixels("\(reading.hour):\(reading.minute)", size: 6)
                    secondsAndPeriod(size: 3)
                }
                pixels(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)), size: 2)
                    .opacity(0.65)
            }
        case .compact:
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .bottom, spacing: 4) {
                    pixels("\(reading.hour):\(reading.minute)", size: 4)
                    secondsAndPeriod(size: 2)
                }
                pixels(date.formatted(.dateTime.weekday(.abbreviated).day()), size: 1.5)
                    .opacity(0.65)
            }
        case .minimal:
            VStack(spacing: 4) {
                pixels(reading.hour, size: 3.5)
                pixels(reading.minute, size: 3.5).opacity(0.75)
                if showsSeconds {
                    pixels(reading.second, size: 1.5).opacity(0.6)
                }
                pixels(date.formatted(.dateTime.weekday(.abbreviated)), size: 1)
                    .opacity(0.5)
                    .padding(.top, 2)
            }
        case .bar:
            HStack(alignment: .bottom, spacing: 6) {
                pixels("\(reading.hour):\(reading.minute)", size: 2.5)
                secondsAndPeriod(size: 1.5)
                pixels(date.formatted(.dateTime.weekday(.abbreviated).day()), size: 1.5).opacity(0.65)
            }
        }
    }

    /// Seconds over the AM/PM period, both smaller than the time and aligned to its baseline.
    @ViewBuilder
    private func secondsAndPeriod(size: CGFloat) -> some View {
        if showsSeconds || reading.period != nil {
            VStack(alignment: .leading, spacing: size * 2) {
                if let period = reading.period {
                    pixels(period, size: size).opacity(0.65)
                }
                if showsSeconds {
                    pixels(reading.second, size: size).opacity(0.65)
                }
            }
        }
    }

    private func pixels(_ text: String, size: CGFloat) -> some View {
        PixelText(text, pixelSize: size, showsUnlitPixels: options.showsUnlitPixels, glows: options.glows)
    }
}
