import SidelightCore
import SwiftUI

/// Hours and minutes on split-flap tiles, like a flip clock or a station board.
struct FlipClockFace: View {
    let date: Date
    let reading: ClockReading
    let options: FlipClockOptions
    let showsSeconds: Bool
    let layout: WidgetLayout
    let alignment: ClockAlignment

    var body: some View {
        content
            .animation(Motion.snappy, value: reading.minuteOfDay)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(date, format: .dateTime.hour().minute().weekday(.wide).day().month(.wide)))
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .regular:
            VStack(alignment: alignment.horizontal, spacing: 9) {
                tiles(height: 56, spacing: 5)
                if options.showsDate {
                    Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        case .compact:
            VStack(alignment: alignment.horizontal, spacing: 6) {
                tiles(height: 38, spacing: 4)
                if options.showsDate {
                    Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        case .minimal:
            // Hours over minutes, like the digital face.
            VStack(spacing: 3) {
                tile(reading.hour, height: 26)
                tile(reading.minute, height: 26)
                if showsSeconds {
                    tile(reading.second, height: 16)
                }
                if options.showsDate {
                    Text(date, format: .dateTime.weekday(.narrow))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        case .bar:
            HStack(spacing: 6) {
                tiles(height: 22, spacing: 2)
                if options.showsDate {
                    Text(date, format: .dateTime.weekday(.abbreviated).day())
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Hours and minutes, then smaller seconds and the AM/PM period along the tiles' bottom edge.
    private func tiles(height: CGFloat, spacing: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: spacing) {
            tile(reading.hour, height: height)
            tile(reading.minute, height: height)
            if showsSeconds {
                // Never so small the hinge would swallow the digits.
                tile(reading.second, height: max(16, (height / 2).rounded()))
            }
            if let period = reading.period {
                Text(period)
                    .font(.system(size: max(8, height * 0.2), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, spacing)
            }
        }
    }

    private func tile(_ text: String, height: CGFloat) -> some View {
        FlipTile(text: text, height: height, tiles: options.tiles)
    }
}

/// One split-flap tile: two flaps with a dark hinge between them, cutting through the digits.
private struct FlipTile: View {
    let text: String
    let height: CGFloat
    let tiles: FlipClockOptions.Tiles

    var body: some View {
        Text(text)
            .font(.system(size: height * 0.7, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(digits)
            .contentTransition(.numericText())
            .frame(width: (height * 1.18).rounded(), height: height)
            .background {
                VStack(spacing: 0) {
                    Rectangle().fill(upper)
                    Rectangle().fill(lower)
                }
            }
            .overlay {
                // In whole Retina pixels: one on bar-sized tiles, three on the largest.
                Rectangle().fill(.black.opacity(hingeOpacity)).frame(height: max(0.5, (height * 0.05).rounded() / 2))
            }
            .clipShape(RoundedRectangle(cornerRadius: height * 0.15, style: .continuous))
            .shadow(color: .black.opacity(tiles == .smoke ? 0 : 0.22), radius: height * 0.03, y: height * 0.02)
    }

    private var hingeOpacity: Double {
        switch tiles {
        case .graphite: 0.6
        case .paper: 0.25
        case .smoke: 0.4
        }
    }

    private var digits: Color {
        switch tiles {
        case .graphite: Color(white: 0.95)
        case .paper: Color(white: 0.13)
        case .smoke: .primary
        }
    }

    /// The upper flap catches a little more light than the lower one.
    private var upper: Color {
        switch tiles {
        case .graphite: Color(white: 0.2)
        case .paper: Color(red: 0.98, green: 0.97, blue: 0.94)
        case .smoke: .primary.opacity(0.15)
        }
    }

    private var lower: Color {
        switch tiles {
        case .graphite: Color(white: 0.15)
        case .paper: Color(red: 0.92, green: 0.9, blue: 0.86)
        case .smoke: .primary.opacity(0.1)
        }
    }
}
