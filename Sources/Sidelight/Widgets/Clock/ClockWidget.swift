import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let clock = WidgetMetadata(
        title: "Clock",
        systemImage: "clock",
        tint: .blue,
        summary: "Time and date, from digits and dials to flip tiles, words and binary."
    )
}

extension ClockStyle {
    var title: String {
        switch self {
        case .digital: "Digital"
        case .analog: "Analog"
        case .pixel: "Pixel"
        case .flip: "Flip"
        case .words: "Words"
        case .binary: "Binary"
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
        case .flip:
            WidgetStyle(
                id: rawValue, title: title, summary: "Digits on split-flap tiles.", family: .retro,
                keywords: ["split flap", "tiles", "station", "70s"])
        case .words:
            WidgetStyle(
                id: rawValue, title: title, summary: "The time in words: nine past ten.", family: .classic,
                keywords: ["text", "spelled", "fuzzy", "typography", "serif"])
        case .binary:
            WidgetStyle(
                id: rawValue, title: title, summary: "A column of bits for every digit.", family: .modern,
                keywords: ["bits", "bcd", "dots", "developer", "geek"])
        }
    }

    /// Analog dials and words are always 12-hour.
    var usesHourFormat: Bool { self != .analog && self != .words }
}

extension ClockSettings {
    var summary: String {
        var parts = [style.title]
        if style.usesHourFormat { parts.append(uses24HourTime ? "24 h" : "12 h") }
        if showsSecondsOnFace { parts.append("seconds") }
        if alignment != .leading { parts.append(alignment.summary) }
        return parts.joined(separator: " · ")
    }
}

extension ClockAlignment {
    var title: String {
        switch self {
        case .leading: "Left"
        case .center: "Center"
        case .trailing: "Right"
        }
    }

    var summary: String {
        switch self {
        case .leading: "left"
        case .center: "centered"
        case .trailing: "right"
        }
    }

    var systemImage: String {
        switch self {
        case .leading: "text.alignleft"
        case .center: "text.aligncenter"
        case .trailing: "text.alignright"
        }
    }

    /// Lines up the time and date with each other.
    var horizontal: HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    /// Where the clock as a whole sits in its card.
    var frame: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    /// For lines of text that wrap.
    var text: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
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

extension ClockColor {
    var title: String {
        switch self {
        case .amber: "Amber"
        case .green: "Green"
        case .cyan: "Cyan"
        case .red: "Red"
        case .text: "Text color"
        }
    }

    /// `nil` for ``text``, which keeps the panel's text color.
    var color: Color? {
        switch self {
        case .amber: Color(red: 1, green: 0.69, blue: 0)
        case .green: Color(red: 0.25, green: 1, blue: 0.4)
        case .cyan: Color(red: 0.3, green: 0.89, blue: 1)
        case .red: Color(red: 1, green: 0.27, blue: 0.27)
        case .text: nil
        }
    }

    /// The color, or the panel's text color for ``text``.
    var style: AnyShapeStyle { color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary) }
}

extension FlipClockOptions.Tiles {
    var title: String {
        switch self {
        case .graphite: "Graphite"
        case .paper: "Paper"
        case .smoke: "Smoke"
        }
    }
}

extension WordClockOptions.Typeface {
    var title: String {
        switch self {
        case .serif: "Serif"
        case .sans: "Sans"
        case .rounded: "Rounded"
        }
    }

    var design: Font.Design {
        switch self {
        case .serif: .serif
        case .sans: .default
        case .rounded: .rounded
        }
    }
}

/// The style itself is picked in the inspector's Style section; this edits what the current style offers.
struct ClockSettingsEditor: View {
    @Binding var settings: ClockSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Alignment", selection: $settings.alignment.animation(Motion.layout)) {
                ForEach(ClockAlignment.allCases) { alignment in
                    Label(alignment.title, systemImage: alignment.systemImage).labelStyle(.iconOnly).tag(alignment)
                }
            }
            .pickerStyle(.segmented)
            Text("In regular and compact cards. Narrow columns always center the clock; bar chips fit it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if settings.style.showsSecondsOption {
            Toggle(settings.style == .analog ? "Second hand" : "Show seconds", isOn: $settings.showsSeconds)
        }
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
            colorPicker($settings.pixel.color)
            Toggle("Show unlit dots", isOn: $settings.pixel.showsUnlitPixels)
            Toggle("Glow", isOn: $settings.pixel.glows)
        case .flip:
            Picker("Tiles", selection: $settings.flip.tiles) {
                ForEach(FlipClockOptions.Tiles.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Show date", isOn: $settings.flip.showsDate)
        case .words:
            Picker("Typeface", selection: $settings.words.typeface) {
                ForEach(WordClockOptions.Typeface.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Round to five minutes", isOn: $settings.words.roundsToFiveMinutes)
            Toggle("Show date", isOn: $settings.words.showsDate)
        case .binary:
            colorPicker($settings.binary.color)
            Toggle("Show digits", isOn: $settings.binary.showsDigits)
        }
    }

    private func colorPicker(_ selection: Binding<ClockColor>) -> some View {
        Picker("Color", selection: selection) {
            ForEach(ClockColor.allCases) { Text($0.title).tag($0) }
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
            aligned(frozenDate)
        } else if settings.showsSecondsOnFace {
            TimelineView(.periodic(from: .now, by: 1)) { context in aligned(context.date) }
        } else {
            TimelineView(.everyMinute) { context in aligned(context.date) }
        }
    }

    /// Regular and compact cards have room to place the clock; minimal cards center it and bar chips fit it.
    @ViewBuilder
    private func aligned(_ date: Date) -> some View {
        switch layout {
        case .regular, .compact:
            face(date, alignment: settings.alignment)
                .frame(maxWidth: .infinity, alignment: settings.alignment.frame)
        case .minimal, .bar:
            face(date, alignment: .center)
        }
    }

    @ViewBuilder
    private func face(_ date: Date, alignment: ClockAlignment) -> some View {
        let reading = ClockReading(date: date, uses24HourTime: settings.uses24HourTime)
        let showsSeconds = settings.showsSecondsOnFace
        switch settings.style {
        case .digital:
            DigitalClockFace(
                date: date, reading: reading, showsSeconds: showsSeconds, layout: layout, alignment: alignment)
        case .analog:
            AnalogClockFace(
                date: date, options: settings.analog, showsSeconds: showsSeconds, layout: layout,
                alignment: alignment)
        case .pixel:
            PixelClockFace(
                date: date, reading: reading, options: settings.pixel, showsSeconds: showsSeconds, layout: layout,
                alignment: alignment)
        case .flip:
            FlipClockFace(
                date: date, reading: reading, options: settings.flip, showsSeconds: showsSeconds, layout: layout,
                alignment: alignment)
        case .words:
            WordClockFace(date: date, options: settings.words, layout: layout, alignment: alignment)
        case .binary:
            BinaryClockFace(
                date: date, reading: reading, options: settings.binary, showsSeconds: showsSeconds, layout: layout,
                alignment: alignment)
        }
    }
}
