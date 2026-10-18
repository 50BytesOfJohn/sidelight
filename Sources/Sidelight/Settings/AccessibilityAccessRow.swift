import SwiftUI

/// Whether Sidelight has Accessibility access, with a way to grant it: shared by the panes that move windows.
struct AccessibilityAccessRow: View {
    @Environment(AccessibilityPermission.self) private var accessibility

    var body: some View {
        LabeledContent("Accessibility access") {
            if accessibility.isTrusted {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Grant Access…") { accessibility.request() }
            }
        }
        // Nothing may be polling for it: look again whenever it's shown.
        .onAppear { accessibility.refresh() }
    }
}
