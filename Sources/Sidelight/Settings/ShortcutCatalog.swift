import Carbon.HIToolbox
import SidelightCore
import SwiftUI

/// One of Sidelight's global shortcuts as Settings offers it.
struct ShortcutSetting: Identifiable {
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

    /// The window manager's action, for one of its shortcuts.
    var windowAction: WindowAction? {
        guard case .window(let action) = action else { return nil }
        return action
    }
}

/// Every shortcut Settings offers, in groups, and what's wrong with each. The Keyboard Shortcuts pane edits the
/// panel's and the stash's; the Window Manager pane edits its own. Both check against all of them.
enum ShortcutCatalog {
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

    /// The window manager's, grouped as its pane shows them.
    static let windowGroups: [(title: String, shortcuts: [ShortcutSetting])] = [
        ("Halves", [.leftHalf, .rightHalf, .topHalf, .bottomHalf].map { window($0) }),
        ("Corners", [.topLeft, .topRight, .bottomLeft, .bottomRight].map { window($0) }),
        (
            "Thirds",
            [.firstThird, .centerThird, .lastThird, .firstTwoThirds, .centerTwoThirds, .lastTwoThirds].map {
                window($0)
            }
        ),
        ("Size & Position", [.maximize, .center, .restore].map { window($0) }),
        ("Displays", [.nextDisplay, .previousDisplay].map { window($0) }),
    ]

    static let window = windowGroups.flatMap(\.shortcuts)

    /// Every one, in ``HotkeyAction`` order.
    static let all = panel + stash + window

    private static func window(_ action: WindowAction) -> ShortcutSetting {
        let title = action.title
        return ShortcutSetting(
            action: .window(action), keyPath: \.windowManager[action: action], title: title,
            name: title.lowercased(), use: action.use)
    }

    /// The shortcut `shortcut` has while it's on.
    static func enabledHotkey(_ shortcut: ShortcutSetting, in configuration: AppConfiguration) -> Hotkey? {
        configuration[keyPath: shortcut.keyPath].ifEnabled
    }

    /// Sidelight's shortcuts that are on, other than `shortcut`, for its recorder to refuse. The window manager's
    /// count only while it's on, or for another of its own, so keys kept for it never block another shortcut.
    static func others(
        than shortcut: ShortcutSetting, in configuration: AppConfiguration
    ) -> [(hotkey: Hotkey, use: String)] {
        let countsWindow = configuration.windowManager.isEnabled || shortcut.windowAction != nil
        return all.filter { $0.action != shortcut.action && (countsWindow || $0.windowAction == nil) }
            .compactMap { other in enabledHotkey(other, in: configuration).map { ($0, other.use) } }
    }

    /// What's wrong with `shortcut`, if it's on. One the same as an earlier one's only does that one's job, as
    /// ``HotkeyCenter`` registers them in ``HotkeyAction`` order; the stash's are only taken while a Stash widget is
    /// placed, so they can't be checked otherwise.
    static func problem(
        for shortcut: ShortcutSetting, in configuration: AppConfiguration, hotkeys: HotkeyCenter
    ) -> String? {
        guard let hotkey = enabledHotkey(shortcut, in: configuration) else { return nil }
        let earlier = all.prefix { $0.action != shortcut.action }
        if let owner = earlier.first(where: {
            enabledHotkey($0, in: configuration)?.isSameShortcut(as: hotkey) == true
        }) {
            return "The \(shortcut.name) shortcut is the same as \(owner.name), so it only \(owner.use)."
        }
        return unavailable(shortcut, hotkeys: hotkeys)
    }

    /// Why `shortcut` couldn't be registered, and which one still works instead, if any.
    private static func unavailable(_ shortcut: ShortcutSetting, hotkeys: HotkeyCenter) -> String? {
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

extension WindowAction {
    var title: String {
        switch self {
        case .leftHalf: "Left half"
        case .rightHalf: "Right half"
        case .topHalf: "Top half"
        case .bottomHalf: "Bottom half"
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        case .firstThird: "First third"
        case .centerThird: "Center third"
        case .lastThird: "Last third"
        case .firstTwoThirds: "First two thirds"
        case .centerTwoThirds: "Center two thirds"
        case .lastTwoThirds: "Last two thirds"
        case .maximize: "Maximize"
        case .center: "Center"
        case .restore: "Restore"
        case .nextDisplay: "Next display"
        case .previousDisplay: "Previous display"
        }
    }

    /// What it does, for a recorder offered the same keys.
    var use: String {
        switch self {
        case .maximize: "maximizes the window"
        case .center: "centers the window"
        case .restore: "puts the window back"
        case .nextDisplay: "moves the window to the next display"
        case .previousDisplay: "moves the window to the previous display"
        default: "moves the window to the \(title.lowercased())"
        }
    }
}

/// A group of shortcuts in a settings form: each with its recorder and switch, then what's wrong with them and
/// `footer` below.
struct ShortcutSection<Footer: View>: View {
    let title: String
    let shortcuts: [ShortcutSetting]
    @ViewBuilder var footer: Footer
    @Environment(ConfigurationStore.self) private var store
    @Environment(HotkeyCenter.self) private var hotkeys

    var body: some View {
        Section {
            ForEach(shortcuts) { row(for: $0) }
        } header: {
            Text(title)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(
                    shortcuts.compactMap {
                        ShortcutCatalog.problem(for: $0, in: store.configuration, hotkeys: hotkeys)
                    },
                    id: \.self
                ) { problem in
                    Text(problem).foregroundStyle(.orange).settingsFootnote()
                }
                footer
            }
        }
    }

    private func row(for shortcut: ShortcutSetting) -> some View {
        let hotkey = Binding(
            get: { store.configuration[keyPath: shortcut.keyPath] },
            set: { store.configuration[keyPath: shortcut.keyPath] = $0 })
        return LabeledContent {
            HStack(alignment: .top, spacing: 10) {
                HotkeyRecorder(hotkey: hotkey, others: ShortcutCatalog.others(than: shortcut, in: store.configuration))
                    .disabled(!hotkey.wrappedValue.isEnabled)
                Toggle(shortcut.title, isOn: hotkey.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.top, 3)
            }
        } label: {
            if let action = shortcut.windowAction {
                Label {
                    Text(shortcut.title)
                } icon: {
                    TileGlyph(action: action)
                }
            } else {
                Text(shortcut.title)
            }
            if let note = shortcut.note { Text(note) }
        }
    }
}

extension ShortcutSection where Footer == SettingsCaption {
    init(_ title: String, _ shortcuts: [ShortcutSetting], footer: String) {
        self.init(title: title, shortcuts: shortcuts) { SettingsCaption(footer) }
    }
}
