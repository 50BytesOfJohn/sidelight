import SwiftUI

/// A section's name in small spaced capitals, as the Widgets window heads its groups: `PANEL`, `ANALOG`.
struct SectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}
