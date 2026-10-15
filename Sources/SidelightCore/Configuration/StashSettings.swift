import Foundation

/// How one Stash widget shows the shared stash. The items themselves live in `stash/items.json`, never here.
public struct StashSettings: Codable, Hashable, Sendable {
    /// What the settings editor offers.
    public static let itemCountRange = 1...10

    /// Open items listed in the regular layout; compact lists fewer.
    public var itemCount = 4
    /// Up to two lines of each item in the regular layout, rather than one.
    public var showsTwoLines = true
    /// The icon of the app each item came from.
    public var showsSourceIcons = true

    public init(itemCount: Int = 4, showsTwoLines: Bool = true, showsSourceIcons: Bool = true) {
        self.itemCount = itemCount
        self.showsTwoLines = showsTwoLines
        self.showsSourceIcons = showsSourceIcons
    }

    /// Missing options take their defaults, and a count the settings don't offer is moved into range.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StashSettings()
        itemCount = try container.decode(.itemCount, or: defaults.itemCount).clamped(to: Self.itemCountRange)
        showsTwoLines = try container.decode(.showsTwoLines, or: defaults.showsTwoLines)
        showsSourceIcons = try container.decode(.showsSourceIcons, or: defaults.showsSourceIcons)
    }
}

/// Which way open items are listed. The queue keeps one order, the one dragging and the move shortcuts change; this
/// only says which end is on top, so switching flips the whole list, an arrangement included, and switching back
/// restores it.
public enum StashOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The oldest on top, new items at the bottom: a queue to work through.
    case oldestFirst
    /// The newest on top.
    case newestFirst

    public var id: Self { self }
}

/// What every Stash widget shares, as the stash is one list: the capture shortcuts, the order open items are listed
/// in, when done items are deleted, the apps nothing is captured from, and whether the selection may be copied with
/// ⌘C.
public struct StashOptions: Codable, Hashable, Sendable {
    /// What the settings editor offers for ``deleteDoneAfterDays``, besides never (0).
    public static let deleteDoneDayChoices = [1, 3, 7, 14, 30]
    public static let deleteDoneDayRange = 0...365

    /// Password managers: what's selected or copied in them is never stashed.
    public static let defaultExcludedApps = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.Passwords",
        "com.apple.keychainaccess", "org.keepassxc.keepassxc",
    ]

    /// Stashes the text selected in the frontmost app.
    public var captureHotkey = Hotkey.defaultStashCapture
    /// Stashes the text on the clipboard.
    public var clipboardHotkey = Hotkey.defaultStashClipboard
    /// Which end of the queue open items are listed from, in every widget and the details panel.
    public var order = StashOrder.oldestFirst
    /// Done items are deleted this many days after they were done, so the stash and its file stay small; 0 keeps them.
    public var deleteDoneAfterDays = 7
    /// Bundle identifiers of apps nothing is captured from.
    public var excludedApps: [String] = StashOptions.defaultExcludedApps
    /// When Accessibility can't read the selection, press ⌘C in the app and put the clipboard back afterwards.
    public var copiesSelectionWithCommandC = true

    public init() {}

    /// Missing options take their defaults, as does one that can't be read, or a shortcut without ⌘, ⌥ or ⌃.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StashOptions()
        captureHotkey = container.decodeLeniently(.captureHotkey, or: defaults.captureHotkey)
        if !captureHotkey.isValid { captureHotkey = defaults.captureHotkey }
        clipboardHotkey = container.decodeLeniently(.clipboardHotkey, or: defaults.clipboardHotkey)
        if !clipboardHotkey.isValid { clipboardHotkey = defaults.clipboardHotkey }
        order = container.decodeLeniently(.order, or: defaults.order)
        deleteDoneAfterDays = container.decodeLeniently(.deleteDoneAfterDays, or: defaults.deleteDoneAfterDays)
            .clamped(to: Self.deleteDoneDayRange)
        excludedApps = container.decodeLeniently(.excludedApps, or: defaults.excludedApps)
        copiesSelectionWithCommandC = container.decodeLeniently(
            .copiesSelectionWithCommandC, or: defaults.copiesSelectionWithCommandC)
    }

    /// How long done items are kept; `nil` while they're kept for good.
    public var deleteDonePeriod: TimeInterval? {
        deleteDoneAfterDays > 0 ? TimeInterval(deleteDoneAfterDays) * 24 * 60 * 60 : nil
    }

    public func excludes(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(excludedApps.contains) ?? false
    }
}
