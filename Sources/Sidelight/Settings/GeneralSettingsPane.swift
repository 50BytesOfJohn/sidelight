import AppKit
import SidelightCore
import SwiftUI

/// Startup, updates and the configuration file.
struct GeneralSettingsPane: View {
    @Environment(ConfigurationStore.self) private var store
    @Environment(LoginItem.self) private var loginItem
    @Environment(Updater.self) private var updater

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
