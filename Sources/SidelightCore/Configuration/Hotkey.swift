import Foundation

/// A global keyboard shortcut in Carbon terms (virtual key code + Carbon modifier mask), which can be turned off.
public struct Hotkey: Codable, Hashable, Sendable {
    /// Carbon modifier flags (`cmdKey`, `shiftKey`, … from `HIToolbox/Events.h`).
    public struct Modifiers: OptionSet, Hashable, Sendable, Codable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 8)
        public static let shift = Modifiers(rawValue: 1 << 9)
        public static let option = Modifiers(rawValue: 1 << 11)
        public static let control = Modifiers(rawValue: 1 << 12)

        /// At least one of these must be present, otherwise the shortcut would swallow normal typing.
        public static let required: Modifiers = [.command, .option, .control]

        /// Glyphs in Apple's canonical order: ⌃⌥⇧⌘.
        public var symbols: String {
            var result = ""
            if contains(.control) { result += "⌃" }
            if contains(.option) { result += "⌥" }
            if contains(.shift) { result += "⇧" }
            if contains(.command) { result += "⌘" }
            return result
        }
    }

    /// Virtual key code (`kVK_*`).
    public var keyCode: UInt32
    public var modifiers: Modifiers
    /// Human-readable name of the key without modifiers, e.g. `S` or `Space`.
    public var key: String
    /// Off, the shortcut is taken from nobody and does nothing, but its keys are kept, so turning it back on brings
    /// the same ones back.
    public var isEnabled = true

    public init(keyCode: UInt32, modifiers: Modifiers, key: String, isEnabled: Bool = true) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
        self.isEnabled = isEnabled
    }

    /// Shortcuts saved before they could be turned off are on, and so is one whose switch can't be read: a typo there
    /// shouldn't make the whole configuration unreadable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        modifiers = try container.decode(Modifiers.self, forKey: .modifiers)
        key = try container.decode(String.self, forKey: .key)
        isEnabled = container.decodeLeniently(.isEnabled, or: true)
    }

    /// ⌥⌘S
    public static let defaultToggle = Hotkey(keyCode: 1, modifiers: [.command, .option], key: "S")

    /// ⌃⌥⌘S, next to the toggle. Not ⇧⌥⌘S, which many apps use for Save As.
    public static let defaultCloseDetails = Hotkey(keyCode: 1, modifiers: [.control, .option, .command], key: "S")

    /// ⌃⌥⌘C, in the same family as closing the details panel: C for capture. Taken only while a Stash widget is
    /// in the configuration.
    public static let defaultStashCapture = Hotkey(keyCode: 8, modifiers: [.control, .option, .command], key: "C")

    /// ⌃⌥⌘V: V for what paste would insert.
    public static let defaultStashClipboard = Hotkey(keyCode: 9, modifiers: [.control, .option, .command], key: "V")

    public var isValid: Bool { !modifiers.isDisjoint(with: .required) }

    /// The shortcut while it's on; `nil` while it's off.
    public var ifEnabled: Hotkey? { isEnabled ? self : nil }

    /// Whether the two are pressed the same way, whatever their keys are called or whether they're on.
    public func isSameShortcut(as other: Hotkey) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    /// The shortcut as shown in menus, e.g. `⌥⌘S`.
    public var displayString: String { modifiers.symbols + key }
}
