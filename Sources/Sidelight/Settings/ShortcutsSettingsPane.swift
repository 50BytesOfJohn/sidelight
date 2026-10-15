import Carbon.HIToolbox
import SidelightCore
import SwiftUI

/// Sidelight's global shortcuts, grouped by what they work on: each can be changed, or turned off.
struct ShortcutsSettingsPane: View {
    @Environment(ConfigurationStore.self) private var store
    @Environment(HotkeyCenter.self) private var hotkeys

    var body: some View {
        Form {
            section(
                "Panel", ShortcutSetting.panel,
                footer: "Shortcuts work from any app. Click one, then press new keys; Esc cancels. Turned off, a "
                    + "shortcut is left to other apps, and keeps its keys for when it's back on. Hiding the panel "
                    + "hides an open details panel too, and showing it brings that back.")
            section(
                "Stash", ShortcutSetting.stash,
                footer: "Taken only while a Stash widget is in a panel, shown or hidden, so they take nothing from "
                    + "other apps otherwise.")
        }
    }

    private func section(_ title: String, _ shortcuts: [ShortcutSetting], footer: String) -> some View {
        Section {
            ForEach(shortcuts) { row(for: $0) }
        } header: {
            Text(title)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(shortcuts.compactMap(problem), id: \.self) { problem in
                    Text(problem).foregroundStyle(.orange).settingsFootnote()
                }
                Text(footer).settingsFootnote()
            }
        }
    }

    private func row(for shortcut: ShortcutSetting) -> some View {
        let hotkey = binding(for: shortcut)
        return LabeledContent {
            HStack(alignment: .top, spacing: 10) {
                HotkeyRecorder(hotkey: hotkey, others: others(than: shortcut))
                    .disabled(!hotkey.wrappedValue.isEnabled)
                Toggle(shortcut.title, isOn: hotkey.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.top, 3)
            }
        } label: {
            Text(shortcut.title)
            if let note = shortcut.note { Text(note) }
        }
    }

    private func binding(for shortcut: ShortcutSetting) -> Binding<Hotkey> {
        Binding(
            get: { store.configuration[keyPath: shortcut.keyPath] },
            set: { store.configuration[keyPath: shortcut.keyPath] = $0 })
    }

    /// The shortcut `shortcut` has while it's on.
    private func enabledHotkey(_ shortcut: ShortcutSetting) -> Hotkey? {
        store.configuration[keyPath: shortcut.keyPath].ifEnabled
    }

    /// Sidelight's shortcuts that are on, other than `shortcut`, for its recorder to refuse.
    private func others(than shortcut: ShortcutSetting) -> [(hotkey: Hotkey, use: String)] {
        ShortcutSetting.all.filter { $0.action != shortcut.action }.compactMap { other in
            enabledHotkey(other).map { ($0, other.use) }
        }
    }

    /// What's wrong with `shortcut`, if it's on. One the same as an earlier one's only does that one's job, as
    /// ``HotkeyCenter`` registers them in ``HotkeyAction`` order; the stash's are only taken while a Stash widget is
    /// placed, so they can't be checked otherwise.
    private func problem(for shortcut: ShortcutSetting) -> String? {
        guard let hotkey = enabledHotkey(shortcut) else { return nil }
        let earlier = ShortcutSetting.all.prefix { $0.action != shortcut.action }
        if let owner = earlier.first(where: { enabledHotkey($0)?.isSameShortcut(as: hotkey) == true }) {
            return "The \(shortcut.name) shortcut is the same as \(owner.name), so it only \(owner.use)."
        }
        return unavailable(shortcut)
    }

    /// Why `shortcut` couldn't be registered, and which one still works instead, if any.
    private func unavailable(_ shortcut: ShortcutSetting) -> String? {
        guard case .unavailable(let status) = hotkeys.problems[shortcut.action] else { return nil }
        let name = shortcut.name
        let problem =
            status == eventHotKeyExistsErr
            ? "Another app has taken the \(name) shortcut for itself, so it can't be used."
            : "The \(name) shortcut couldn't be registered (status \(status)); another app may be using it."
        guard let working = hotkeys.workingHotkey(for: shortcut.action) else { return problem }
        return problem + " \(working.displayString) still works meanwhile."
    }
}

/// One of Sidelight's global shortcuts as Settings offers it.
private struct ShortcutSetting: Identifiable {
    let action: HotkeyAction
    let keyPath: WritableKeyPath<AppConfiguration, Hotkey>
    let title: String
    /// When it's taken, if not always.
    var note: String?
    /// What problems call it.
    let name: String
    /// What it does, for a recorder offered the same keys.
    let use: String

    var id: HotkeyAction { action }

    static let panel = [
        ShortcutSetting(
            action: .togglePanels, keyPath: \.hotkey, title: "Show or hide the panel", name: "show or hide",
            use: "shows or hides the panel"),
        ShortcutSetting(
            action: .closeDetails, keyPath: \.details.closeHotkey, title: "Close the details panel",
            note: "Only taken while a details panel is open.", name: "close", use: "closes the details panel"),
    ]

    static let stash = [
        ShortcutSetting(
            action: .stashSelection, keyPath: \.stash.captureHotkey, title: "Stash the selection",
            name: "stash selection", use: "stashes the selection"),
        ShortcutSetting(
            action: .stashClipboard, keyPath: \.stash.clipboardHotkey, title: "Stash the clipboard",
            name: "stash clipboard", use: "stashes the clipboard"),
    ]

    /// Every one, in ``HotkeyAction`` order.
    static let all = panel + stash
}
