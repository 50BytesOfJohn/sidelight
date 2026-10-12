import SwiftUI

/// Secondary explanatory text under a settings control.
struct SettingsCaption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).settingsFootnote()
    }
}

extension View {
    /// Secondary explanatory text under a settings section. For text built with markdown or interpolation, where
    /// ``SettingsCaption`` takes only a string.
    func settingsFootnote() -> some View {
        font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
