import SidelightCore
import SwiftUI

/// Sidelight's global shortcuts, grouped by what they work on: each can be changed, or turned off. The window
/// manager's have their own pane, linked from here, so each shortcut has one editor.
struct ShortcutsSettingsPane: View {
    @Environment(SettingsNavigator.self) private var navigator

    var body: some View {
        Form {
            ShortcutSection(
                "Panel", ShortcutCatalog.panel,
                footer: "Shortcuts work from any app. Click one, then press new keys; Esc cancels. Turned off, a "
                    + "shortcut is left to other apps, and keeps its keys for when it's back on. Hiding the panel "
                    + "hides an open details panel too, and showing it brings that back.")
            ShortcutSection(
                "Stash", ShortcutCatalog.stash,
                footer: "Taken only while a Stash widget is in a panel, shown or hidden, so they take nothing from "
                    + "other apps otherwise.")
            Section {
                LabeledContent("Window manager shortcuts") {
                    Button("Window Manager…") { navigator.showWindowManager() }
                }
            }
        }
    }
}
