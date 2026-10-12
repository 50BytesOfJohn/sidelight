import SwiftUI

/// The switch for a widget that fetches its data on a timer, and how often. The interval is disabled while the
/// switch is off.
struct RefreshIntervalPicker: View {
    let title: String
    @Binding var isOn: Bool
    @Binding var minutes: Int
    /// The offered intervals; one set by hand in `config.json` is listed too, so the picker always shows the real
    /// value.
    let choices: [Int]

    var body: some View {
        Toggle(title, isOn: $isOn)
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

    var body: some View {
        Picker("Keep finished for", selection: $hours) {
            ForEach(choices, id: \.self) { Text("\($0) h").tag($0) }
        }
        .pickerStyle(.segmented)
    }
}
