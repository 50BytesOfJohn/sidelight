import SwiftUI

/// The switch for a widget that fetches its data on a timer, and how often. The interval is disabled while the
/// switch is off.
struct RefreshIntervalPicker: View {
    let title: String
    /// Where the data comes from, behind an ⓘ next to the switch.
    var info: String?
    @Binding var isOn: Bool
    @Binding var minutes: Int
    /// The offered intervals; one set by hand in `config.json` is listed too, so the picker always shows the real
    /// value.
    let choices: [Int]

    var body: some View {
        Toggle(isOn: $isOn) {
            if let info { InfoLabel(title, info: info) } else { Text(title) }
        }
        Picker("Every", selection: $minutes) {
            ForEach(Set(choices + [minutes]).sorted(), id: \.self) { Text("\($0) min").tag($0) }
        }
        .disabled(!isOn)
    }
}

/// How many sessions a sessions widget lists.
struct SessionsListedStepper: View {
    @Binding var count: Int
    let range: ClosedRange<Int>

    var body: some View {
        Stepper("Sessions listed: \(count)", value: $count, in: range)
    }
}

/// How long finished, idle and closed sessions stay listed.
struct KeepFinishedPicker: View {
    @Binding var hours: Int
    let choices: [Int]
    /// What else stays listed for as long, if anything.
    var alsoKept: String?

    var body: some View {
        Picker(selection: $hours) {
            ForEach(choices, id: \.self) { Text("\($0) h").tag($0) }
        } label: {
            InfoLabel(
                "Keep finished for",
                info: "Working sessions and ones that need you always show. Finished, idle and closed ones stay "
                    + "this long." + (alsoKept.map { " \($0)" } ?? ""))
        }
        .pickerStyle(.segmented)
    }
}
