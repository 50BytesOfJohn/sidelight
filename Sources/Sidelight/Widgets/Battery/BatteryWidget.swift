import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let battery = WidgetMetadata(
        title: "Battery",
        systemImage: "battery.75percent",
        tint: .green,
        summary: "Charge, charging and time left",
        details:
            "Updates whenever macOS reports a change to the battery or the power adapter, and never on a timer. Power "
            + "in watts comes from the battery's own controller, read only while a widget shows it."
    )
}

extension BatteryStyle {
    var title: String {
        switch self {
        case .glyph: "Glyph"
        case .ring: "Ring"
        case .cell: "Cell"
        case .pixel: "Pixel"
        }
    }

    var widgetStyle: WidgetStyle {
        switch self {
        case .glyph:
            WidgetStyle(
                id: rawValue, title: title, summary: "The battery glyph and percentage on one line.", family: .modern,
                keywords: ["menu bar", "icon", "slim", "line", "small"])
        case .ring:
            WidgetStyle(
                id: rawValue, title: title, summary: "A ring around the percentage.", family: .modern,
                keywords: ["gauge", "circle", "dial", "arc"])
        case .cell:
            WidgetStyle(
                id: rawValue, title: title, summary: "A large battery cell, filled to the charge.", family: .classic,
                keywords: ["large", "glass", "aqua", "bar"])
        case .pixel:
            WidgetStyle(
                id: rawValue, title: title, summary: "Dot-matrix digits and a segmented cell.", family: .retro,
                keywords: ["lcd", "led", "8-bit", "dot matrix", "segments"])
        }
    }
}

extension BatterySettings {
    var summary: String {
        var parts = [style.title]
        if showsTimeRemaining { parts.append("time left") }
        if showsPower { parts.append("watts") }
        return parts.joined(separator: " · ")
    }
}

extension RingBatteryOptions.Gauge {
    var title: String {
        switch self {
        case .solid: "Solid"
        case .ticks: "Ticks"
        }
    }
}

extension CellBatteryOptions.Finish {
    var title: String {
        switch self {
        case .glass: "Glass"
        case .flat: "Flat"
        }
    }
}

extension BatteryTone {
    /// Battery colors, not usage colors: a full battery is good news, so it stays in the text color.
    var color: Color {
        switch self {
        case .normal: .primary
        case .charging: .green
        case .lowPower: .yellow
        case .low: .orange
        case .critical: .red
        }
    }
}

/// The style itself is picked in the inspector's Style section; this edits what the current style offers.
struct BatterySettingsEditor: View {
    @Binding var settings: BatterySettings

    var body: some View {
        Toggle("Show time left", isOn: $settings.showsTimeRemaining)
        Toggle(isOn: $settings.showsPower) {
            InfoLabel(
                "Show power",
                info: "Watts going into the battery while it charges, or out of it on battery, from the battery's own "
                    + "controller. Updates as macOS reports changes to the battery.")
        }
        switch settings.style {
        case .glyph:
            Toggle("Show percentage", isOn: $settings.glyph.showsPercent)
        case .ring:
            Picker("Gauge", selection: $settings.ring.gauge) {
                ForEach(RingBatteryOptions.Gauge.allCases) { Text($0.title).tag($0) }
            }
        case .cell:
            Picker("Finish", selection: $settings.cell.finish) {
                ForEach(CellBatteryOptions.Finish.allCases) { Text($0.title).tag($0) }
            }
        case .pixel:
            Picker(selection: $settings.pixel.color) {
                ForEach(ClockColor.allCases) { Text($0.title).tag($0) }
            } label: {
                InfoLabel(
                    "Color", info: "Charging, a low battery and Low Power Mode light the dots in their own color.")
            }
            Toggle("Show unlit dots", isOn: $settings.pixel.showsUnlitPixels)
            Toggle("Glow", isOn: $settings.pixel.glows)
        }
    }
}

/// The Mac's battery in the chosen style, or why there's none to show.
struct BatteryWidgetView: View {
    let settings: BatterySettings
    let layout: WidgetLayout
    @Environment(BatteryService.self) private var battery
    @Environment(\.isWidgetPreview) private var isPreview

    var body: some View {
        if let reading {
            face(reading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Battery")
                .accessibilityValue(BatteryText.accessibilityValue(reading, showsPower: settings.showsPower))
                .help(layout.isGlanceable ? help(reading) : "")
        } else if battery.snapshot == .noBattery {
            WidgetMessage(
                title: "No battery", detail: "This Mac runs on power from the wall.", systemImage: "powerplug",
                layout: layout)
        } else {
            WidgetMessage(title: "Reading the battery", systemImage: "battery.0percent", layout: layout)
        }
    }

    /// The real battery, or in previews on a Mac without one, an example, so every style can still be seen.
    private var reading: BatteryReading? {
        if let reading = battery.snapshot.reading { return reading }
        return isPreview ? .sample : nil
    }

    @ViewBuilder
    private func face(_ reading: BatteryReading) -> some View {
        switch settings.style {
        case .glyph: GlyphBatteryFace(reading: reading, settings: settings, layout: layout)
        case .ring: RingBatteryFace(reading: reading, settings: settings, layout: layout)
        case .cell: CellBatteryFace(reading: reading, settings: settings, layout: layout)
        case .pixel: PixelBatteryFace(reading: reading, settings: settings, layout: layout)
        }
    }

    /// `76% · On battery · 3h 12m left`.
    private func help(_ reading: BatteryReading) -> String {
        let detail = BatteryText.detail(
            reading, showsTimeRemaining: settings.showsTimeRemaining, showsPower: settings.showsPower)
        return "\(BatteryText.percent(reading)) · \(detail)"
    }
}

// MARK: - Shared parts

/// A battery outline with a terminal, filled from the leading edge to the charge: the menu bar's glyph when small,
/// a classic cell when large. Only the fill animates, and only when the charge changes.
struct BatteryCell: View {
    let percent: Int
    let color: Color
    /// The whole cell's width, terminal included; `nil` takes the width offered.
    var width: CGFloat?
    let height: CGFloat
    var finish: CellBatteryOptions.Finish = .flat
    var showsBolt = false
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        let line = max(1, height * 0.08)
        let radius = height * 0.3
        let inset = line + max(1, height * 0.07)
        let terminalWidth = max(1.5, height * 0.12)
        let spacing = max(0.5, height * 0.05)
        HStack(spacing: spacing) {
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(finish == .glass ? 0.07 : 0.04))
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.4), lineWidth: line)
                fill(cornerRadius: max(0.5, radius - inset))
                    .padding(inset)
                if showsBolt {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: height * 0.62, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 0.8)
                }
            }
            .frame(width: width.map { max(0, $0 - terminalWidth - spacing) }, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            UnevenRoundedRectangle(bottomTrailingRadius: terminalWidth * 0.6, topTrailingRadius: terminalWidth * 0.6)
                .fill(Color.primary.opacity(0.4))
                .frame(width: terminalWidth, height: height * 0.36)
        }
        .accessibilityHidden(true)
    }

    private func fill(cornerRadius: CGFloat) -> some View {
        GeometryReader { proxy in
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            Group {
                switch finish {
                case .flat:
                    shape.fill(color)
                case .glass:
                    shape.fill(
                        LinearGradient(colors: [color.opacity(0.7), color], startPoint: .top, endPoint: .bottom)
                    )
                    .overlay(alignment: .top) {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.55), .white.opacity(0.05)], startPoint: .top,
                                    endPoint: .bottom)
                            )
                            .frame(height: proxy.size.height * 0.45)
                            .padding(.horizontal, proxy.size.height * 0.15)
                            .padding(.top, proxy.size.height * 0.06)
                    }
                }
            }
            .mask(alignment: .leading) {
                Rectangle().frame(width: proxy.size.width * CGFloat(percent) / 100)
            }
            .animation(reducesMotion ? nil : Motion.gentle, value: percent)
        }
    }
}

/// A small green bolt beside text, while the battery charges.
struct ChargingBolt: View {
    let reading: BatteryReading
    let size: CGFloat

    var body: some View {
        if reading.state == .charging {
            Image(systemName: "bolt.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(BatteryTone.charging.color)
        }
    }
}
