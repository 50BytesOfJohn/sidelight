import AppKit
import SidelightCore
import SwiftUI

/// Startup, updates, the global shortcut and the configuration file.
struct GeneralSettingsPane: View {
    @Environment(ConfigurationStore.self) private var store
    @Environment(HotkeyCenter.self) private var hotkeys
    @Environment(LoginItem.self) private var loginItem
    @Environment(Updater.self) private var updater

    /// What's wrong with the shortcuts, one line each.
    private var problems: [String] {
        let configuration = store.configuration
        var problems: [String] = []
        if case .unavailable(let status) = hotkeys.problems[.togglePanels] {
            problems.append(
                "The show or hide shortcut couldn't be registered (status \(status)); another app may be using it.")
        }
        if configuration.details.closeHotkey == configuration.hotkey {
            problems.append("The close shortcut is the same as show or hide, so it only shows or hides the panel.")
        } else if case .unavailable(let status) = hotkeys.problems[.closeDetails] {
            problems.append(
                "The close shortcut couldn't be registered (status \(status)); another app may be using it.")
        }
        return problems
    }

    var body: some View {
        @Bindable var store = store

        Form {
            Section("Startup") {
                Toggle(isOn: Binding(get: { loginItem.isEnabled }, set: loginItem.setEnabled)) {
                    Text("Launch at login")
                    if !loginItem.isEnabled {
                        Text(loginItem.statusDescription)
                    }
                }
                if let error = loginItem.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Check for updates automatically", isOn: $store.configuration.updates.checksAutomatically)
                Toggle(
                    "Download and install updates automatically",
                    isOn: $store.configuration.updates.installsAutomatically
                )
                .disabled(!store.configuration.updates.checksAutomatically)
                LabeledContent {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                } label: {
                    Text("Sidelight \(updater.currentVersion)")
                    if let version = updater.availableVersion {
                        Text("Version \(version) is available")
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Updates downloaded in the background are installed when Sidelight quits.")
                    .settingsFootnote()
            }

            Section {
                LabeledContent("Show or hide the panel") {
                    HotkeyRecorder(hotkey: $store.configuration.hotkey)
                }
                LabeledContent {
                    HotkeyRecorder(hotkey: $store.configuration.details.closeHotkey)
                } label: {
                    Text("Close the details panel")
                    Text("Only taken while a details panel is open.")
                }
            } header: {
                Text("Keyboard")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(problems, id: \.self) { problem in
                        Text(problem).foregroundStyle(.orange).settingsFootnote()
                    }
                    Text(
                        "Both work from any app. Click a shortcut, then press a new one; Esc cancels. Hiding the panel "
                            + "hides an open details panel too, and showing it brings that back."
                    )
                    .settingsFootnote()
                }
            }

            Section {
                LabeledContent {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) }
                } label: {
                    Text("config.json")
                    Text(store.fileURL.deletingLastPathComponent().path(percentEncoded: false))
                        .truncationMode(.middle)
                }
            } header: {
                Text("Configuration File")
            } footer: {
                Text("Every setting lives in this file. Edits made by hand are applied as soon as it's saved.")
                    .settingsFootnote()
            }
        }
    }
}
