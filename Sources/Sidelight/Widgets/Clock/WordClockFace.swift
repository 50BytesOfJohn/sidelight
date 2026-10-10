import SidelightCore
import SwiftUI

/// The time in words, minutes over the hour: "nine past" over "ten".
struct WordClockFace: View {
    let date: Date
    let options: WordClockOptions
    let layout: WidgetLayout
    let alignment: ClockAlignment

    private var phrase: ClockPhrase { ClockPhrase(date: date, roundsToFiveMinutes: options.roundsToFiveMinutes) }

    var body: some View {
        content
            .animation(Motion.snappy, value: phrase)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(phrase.text), \(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))")
    }

    @ViewBuilder
    private var content: some View {
        let phrase = phrase
        switch layout {
        case .regular:
            VStack(alignment: alignment.horizontal, spacing: 0) {
                lead(phrase, size: 18)
                hour(phrase, size: 34, oClockSize: 18)
                if options.showsDate {
                    Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 5)
                }
            }
        case .compact:
            VStack(alignment: alignment.horizontal, spacing: 0) {
                lead(phrase, size: 13)
                hour(phrase, size: 24, oClockSize: 13)
                if options.showsDate {
                    Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                }
            }
        case .minimal:
            // One word a line, always three lines: "nine / past / ten", "it's / ten / o'clock".
            VStack(spacing: 0) {
                if let lead = phrase.lead {
                    ForEach(lead.split(separator: " ").map(String.init), id: \.self) { word in
                        line(word, size: 10).foregroundStyle(.secondary)
                    }
                } else {
                    line("it's", size: 10).foregroundStyle(.secondary)
                }
                line(phrase.hour, size: 15, weight: .semibold)
                if phrase.isOClock {
                    line("o'clock", size: 10).foregroundStyle(.secondary)
                }
                if options.showsDate {
                    Text(date, format: .dateTime.weekday(.narrow))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
        case .bar:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                sentence(phrase)
                    .font(font(size: 13))
                    .lineLimit(1)
                    .fixedSize()
                if options.showsDate {
                    Text(date, format: .dateTime.weekday(.abbreviated).day())
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The whole phrase on one line, the hour emphasized.
    private func sentence(_ phrase: ClockPhrase) -> Text {
        let hour = Text(phrase.hour).fontWeight(.semibold)
        let oClock = Text(phrase.isOClock ? " o'clock" : "").foregroundStyle(.secondary)
        guard let lead = phrase.lead else { return Text("\(hour)\(oClock)") }
        return Text("\(Text(lead + " ").foregroundStyle(.secondary))\(hour)\(oClock)")
    }

    /// The minutes and which way they count, or "it's" on the hour, so the face keeps its height.
    private func lead(_ phrase: ClockPhrase, size: CGFloat) -> some View {
        line(phrase.lead ?? "it's", size: size).foregroundStyle(.secondary)
    }

    private func hour(_ phrase: ClockPhrase, size: CGFloat, oClockSize: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: oClockSize * 0.3) {
            line(phrase.hour, size: size, weight: .semibold)
            if phrase.isOClock {
                line("o'clock", size: oClockSize).foregroundStyle(.secondary)
            }
        }
    }

    private func line(_ text: String, size: CGFloat, weight: Font.Weight = .regular) -> some View {
        Text(text)
            .font(font(size: size, weight: weight))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .contentTransition(.interpolate)
    }

    private func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: options.typeface.design)
    }
}
