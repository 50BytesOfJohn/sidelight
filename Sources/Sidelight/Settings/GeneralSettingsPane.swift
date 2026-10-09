import AppKit
import SidelightCore
import SwiftUI

/// Startup, the global shortcut and the configuration file.
struct GeneralSettingsPane: View {
    @Environment(ConfigurationStore.self) private var store
    @Environment(HotkeyCenter.self) private var hotkeys
    @Environment(LoginItem.self) private var loginItem

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
                LabeledContent("Show or hide the panel") {
                    HotkeyRecorder(hotkey: $store.configuration.hotkey)
                }
            } header: {
                Text("Keyboard")
            } footer: {
                if let status = hotkeys.registrationError {
                    Text("This shortcut couldn't be registered (status \(status)); another app may be using it.")
                        .foregroundStyle(.orange)
                        .settingsFootnote()
                } else {
                    Text("Works from any app. Click the shortcut, then press a new one; Esc cancels.")
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
