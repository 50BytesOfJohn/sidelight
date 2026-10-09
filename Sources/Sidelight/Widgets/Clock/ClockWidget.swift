import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let clock = WidgetMetadata(
        title: "Clock",
        systemImage: "clock",
        tint: .blue,
        summary: "Time and date, as a digital, analog or pixel face."
    )
}

extension ClockStyle {
    var title: String {
        switch self {
        case .digital: "Digital"
        case .analog: "Analog"
        case .pixel: "Pixel"
        }
    }

    var widgetStyle: WidgetStyle {
        switch self {
        case .digital:
            WidgetStyle(
                id: rawValue, title: title, summary: "Large rounded digits.", family: .modern,
                keywords: ["numbers", "simple"])
        case .analog:
            WidgetStyle(
                id: rawValue, title: title, summary: "Hands on a dial.", family: .classic,
                keywords: ["watch", "hands", "dial"])
        case .pixel:
            WidgetStyle(
                id: rawValue, title: title, summary: "Dot-matrix digits, like an old LCD.", family: .retro,
                keywords: ["lcd", "led", "8-bit", "dot matrix"])
        }
    }

    /// Analog dials are always 12-hour.
    var usesHourFormat: Bool { self != .analog }
}

extension ClockSettings {
    var summary: String {
        var parts = [style.title]
        if style.usesHourFormat { parts.append(uses24HourTime ? "24 h" : "12 h") }
        if showsSeconds { parts.append("seconds") }
        return parts.joined(separator: " · ")
    }

}

extension AnalogClockOptions.Dial {
    var title: String {
        switch self {
        case .ticks: "Ticks"
        case .numerals: "Numerals"
        case .minimal: "Minimal"
        }
    }
}

extension PixelClockOptions.Color {
    var title: String {
        switch self {
        case .amber: "Amber"
        case .green: "Green"
        case .cyan: "Cyan"
        case .red: "Red"
        case .text: "Text color"
        }
    }

    /// `nil` for ``text``, which keeps the panel's text color. Inside this extension `Color` is the enum itself.
    var color: SwiftUI.Color? {
        switch self {
        case .amber: SwiftUI.Color(red: 1, green: 0.69, blue: 0)
        case .green: SwiftUI.Color(red: 0.25, green: 1, blue: 0.4)
        case .cyan: SwiftUI.Color(red: 0.3, green: 0.89, blue: 1)
        case .red: SwiftUI.Color(red: 1, green: 0.27, blue: 0.27)
        case .text: nil
        }
    }
}

/// The style itself is picked in the inspector's Style section; this edits what the current style offers.
struct ClockSettingsEditor: View {
    @Binding var settings: ClockSettings

    var body: some View {
        Toggle(settings.style == .analog ? "Second hand" : "Show seconds", isOn: $settings.showsSeconds)
        if settings.style.usesHourFormat {
            Toggle("24-hour time", isOn: $settings.uses24HourTime)
        }
        switch settings.style {
        case .digital:
            EmptyView()
        case .analog:
            Picker("Dial", selection: $settings.analog.dial) {
                ForEach(AnalogClockOptions.Dial.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Show date", isOn: $settings.analog.showsDate)
        case .pixel:
            Picker("Color", selection: $settings.pixel.color) {
                ForEach(PixelClockOptions.Color.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Show unlit dots", isOn: $settings.pixel.showsUnlitPixels)
            Toggle("Glow", isOn: $settings.pixel.glows)
        }
    }
}

struct ClockWidgetView: View {
    let settings: ClockSettings
    let layout: WidgetLayout
    @Environment(\.frozenDate) private var frozenDate

    var body: some View {
        // Redraw once a minute unless seconds are shown: a per-second timeline costs measurable energy.
        if let frozenDate {
            face(frozenDate)
        } else if settings.showsSeconds {
            TimelineView(.periodic(from: .now, by: 1)) { context in face(context.date) }
        } else {
            TimelineView(.everyMinute) { context in face(context.date) }
        }
    }

    @ViewBuilder
    private func face(_ date: Date) -> some View {
        let reading = ClockReading(date: date, uses24HourTime: settings.uses24HourTime)
        switch settings.style {
        case .digital:
            DigitalClockFace(date: date, reading: reading, showsSeconds: settings.showsSeconds, layout: layout)
        case .analog:
            AnalogClockFace(date: date, options: settings.analog, showsSeconds: settings.showsSeconds, layout: layout)
        case .pixel:
            PixelClockFace(
                date: date, reading: reading, options: settings.pixel, showsSeconds: settings.showsSeconds,
                layout: layout)
        }
    }
}
