import Foundation

/// A global keyboard shortcut in Carbon terms (virtual key code + Carbon modifier mask).
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

    public init(keyCode: UInt32, modifiers: Modifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// ⌥⌘S
    public static let defaultToggle = Hotkey(keyCode: 1, modifiers: [.command, .option], key: "S")

    public var isValid: Bool { !modifiers.isDisjoint(with: .required) }

    /// The shortcut as shown in menus, e.g. `⌥⌘S`.
    public var displayString: String { modifiers.symbols + key }
}
