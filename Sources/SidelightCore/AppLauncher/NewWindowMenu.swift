import Foundation

/// One item in an app's menu bar, as Accessibility reads it.
public struct MenuItemInfo: Hashable, Sendable {
    public var title: String
    /// The shortcut's key, such as `N`; `nil` without one.
    public var commandKey: String?
    /// `AXMenuItemCmdModifiers`: 0 is ⌘ alone; 1 adds ⇧, 2 ⌥, 4 ⌃, and 8 means no ⌘.
    public var modifiers: Int
    public var isEnabled: Bool
    /// Indexes from the menu bar down to the item, to find it again and press it.
    public var path: [Int]

    public init(title: String, commandKey: String?, modifiers: Int, isEnabled: Bool = true, path: [Int]) {
        self.title = title
        self.commandKey = commandKey
        self.modifiers = modifiers
        self.isEnabled = isEnabled
        self.path = path
    }

    /// ⌘N with nothing else held.
    var isCommandN: Bool { commandKey?.uppercased() == "N" && modifiers == 0 }
}

/// Which menu item means "new window" in an app. No API asks an app for that, but nearly every app has one in its
/// menu bar; the titles and shortcuts differ, so the match is ranked rather than a title search. In kitty, "New
/// Window" is a split, and the window is "New OS Window" on ⌘N.
public enum NewWindowMenu {
    /// Words that mean the item opens something other than a window. English only: in other languages, rule 3 below
    /// (⌘N) takes over, which is the right item in most apps anyway.
    public static let excludedWords = ["Tab", "Incognito", "Private", "Split"]
    public static let windowWords = ["Window"]
    public static let newWindowTitles = ["New Window"]

    /// The item to press, from enabled ones only, the Apple menu (the first) left out:
    /// 1. ⌘N, with nothing else held, titled with "Window" (Finder, Chrome, kitty's "New OS Window").
    /// 2. An item titled exactly "New Window" on N, with any modifiers (Zed's ⌘⇧N).
    /// 3. ⌘N, with nothing else held, whatever its title ("New", "New Document"): what the app calls new.
    ///
    /// Titles with any of ``excludedWords`` never match. `nil` when nothing does.
    public static func best(in items: [MenuItemInfo]) -> MenuItemInfo? {
        let candidates = items.filter { item in
            item.isEnabled && item.path.first != 0
                && !excludedWords.contains { item.title.localizedCaseInsensitiveContains($0) }
        }
        if let item = candidates.first(where: { item in
            item.isCommandN && windowWords.contains { item.title.localizedCaseInsensitiveContains($0) }
        }) {
            return item
        }
        if let item = candidates.first(where: { item in
            item.commandKey?.uppercased() == "N"
                && newWindowTitles.contains { item.title.compare($0, options: .caseInsensitive) == .orderedSame }
        }) {
            return item
        }
        return candidates.first(where: \.isCommandN)
    }
}
