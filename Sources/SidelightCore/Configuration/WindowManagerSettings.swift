import Foundation

/// The built-in window manager: shortcuts that move and resize the frontmost window into tiles. Off by default.
public struct WindowManagerSettings: Codable, Equatable, Sendable {
    public var isEnabled = false
    /// Between neighbouring tiles, in points.
    public var gap = 8
    /// Along the screen's edges, in points. Beside a panel the space is always window avoidance's gap.
    public var padding = 8
    /// Pressing a half again soon goes ½ → ⅓ → ⅔.
    public var cyclesSizes = true
    /// Every action's shortcut, kept for each even while switched off. Saved in full, so a later release never
    /// remaps saved keys.
    public var shortcuts: [WindowAction: Hotkey] = WindowManagerPreset.sidelight.shortcuts

    public init() {}

    /// `action`'s shortcut, for settings rows to bind to.
    public subscript(action action: WindowAction) -> Hotkey {
        get { shortcuts[action] ?? WindowManagerPreset.sidelight.binding(for: action) }
        set { shortcuts[action] = newValue }
    }

    /// The preset these shortcuts are, keys and switches; `nil` for a custom set.
    public var preset: WindowManagerPreset? { WindowManagerPreset.matching(shortcuts) }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, gap, padding, cyclesSizes, shortcuts
    }

    /// Missing or unreadable options take their defaults, and spacing is moved into what the settings offer. One
    /// unreadable shortcut, or one without ⌘, ⌥ or ⌃, falls back to the Sidelight preset's for that action alone; an
    /// action only a newer version knows is dropped. An action missing from saved shortcuts (one added since they were
    /// saved) arrives switched off, so an update never takes a global shortcut without asking.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WindowManagerSettings()
        isEnabled = container.decodeLeniently(.isEnabled, or: defaults.isEnabled)
        gap = container.decodeLeniently(.gap, or: defaults.gap).clamped(to: WindowLayout.spacingRange)
        padding = container.decodeLeniently(.padding, or: defaults.padding).clamped(to: WindowLayout.spacingRange)
        cyclesSizes = container.decodeLeniently(.cyclesSizes, or: defaults.cyclesSizes)
        let saved = container.decodeLeniently(.shortcuts, or: [String: LenientElement<Hotkey>]())
        guard !saved.isEmpty else { return }
        let preset = WindowManagerPreset.sidelight
        shortcuts = Dictionary(
            uniqueKeysWithValues: WindowAction.allCases.map { action in
                guard let entry = saved[action.rawValue] else {
                    var added = preset.binding(for: action)
                    added.isEnabled = false
                    return (action, added)
                }
                guard let hotkey = entry.value, hotkey.isValid else { return (action, preset.binding(for: action)) }
                return (action, hotkey)
            })
    }
}

/// A ready-made set of window shortcuts. Applying one replaces every window shortcut, keys and switches; which one is
/// in use is worked out from the shortcuts, never saved, so it can't go stale.
public enum WindowManagerPreset: String, CaseIterable, Identifiable, Sendable {
    /// Rectangle's keys, with the explicit thirds switched off: cycling a half already reaches them, and ⌃⌥D, E, F,
    /// G, R and T stay with other apps until wanted.
    case sidelight
    /// Rectangle's own defaults, every action on.
    case rectangle
    /// Spectacle's keys. It has no thirds of its own, so those keep Rectangle's keys, switched off.
    case spectacle

    public var id: Self { self }

    public var title: String {
        switch self {
        case .sidelight: "Sidelight"
        case .rectangle: "Rectangle"
        case .spectacle: "Spectacle"
        }
    }

    /// Every action's shortcut in this preset.
    public var shortcuts: [WindowAction: Hotkey] {
        Dictionary(uniqueKeysWithValues: WindowAction.allCases.map { ($0, binding(for: $0)) })
    }

    /// The preset whose shortcuts these are, pressed the same way and switched the same; `nil` for none.
    public static func matching(_ shortcuts: [WindowAction: Hotkey]) -> WindowManagerPreset? {
        allCases.first { preset in
            WindowAction.allCases.allSatisfy { action in
                guard let hotkey = shortcuts[action] else { return false }
                let binding = preset.binding(for: action)
                return hotkey.isSameShortcut(as: binding) && hotkey.isEnabled == binding.isEnabled
            }
        }
    }

    public func binding(for action: WindowAction) -> Hotkey {
        let controlOption: Hotkey.Modifiers = [.control, .option]
        let optionCommand: Hotkey.Modifiers = [.option, .command]
        let controlCommand: Hotkey.Modifiers = [.control, .command]
        let controlShiftCommand: Hotkey.Modifiers = [.control, .shift, .command]
        let hyper: Hotkey.Modifiers = [.control, .option, .command]
        func key(_ code: Key, _ modifiers: Hotkey.Modifiers, on isEnabled: Bool = true) -> Hotkey {
            Hotkey(keyCode: code.code, modifiers: modifiers, key: code.name, isEnabled: isEnabled)
        }
        let thirdsOn = self == .rectangle
        switch (self, action) {
        case (.spectacle, .leftHalf): return key(.left, optionCommand)
        case (.spectacle, .rightHalf): return key(.right, optionCommand)
        case (.spectacle, .topHalf): return key(.up, optionCommand)
        case (.spectacle, .bottomHalf): return key(.down, optionCommand)
        case (.spectacle, .topLeft): return key(.left, controlCommand)
        case (.spectacle, .topRight): return key(.right, controlCommand)
        case (.spectacle, .bottomLeft): return key(.left, controlShiftCommand)
        case (.spectacle, .bottomRight): return key(.right, controlShiftCommand)
        case (.spectacle, .maximize): return key(.f, optionCommand)
        case (.spectacle, .center): return key(.c, optionCommand)
        case (_, .leftHalf): return key(.left, controlOption)
        case (_, .rightHalf): return key(.right, controlOption)
        case (_, .topHalf): return key(.up, controlOption)
        case (_, .bottomHalf): return key(.down, controlOption)
        case (_, .topLeft): return key(.u, controlOption)
        case (_, .topRight): return key(.i, controlOption)
        case (_, .bottomLeft): return key(.j, controlOption)
        case (_, .bottomRight): return key(.k, controlOption)
        case (_, .firstThird): return key(.d, controlOption, on: thirdsOn)
        case (_, .centerThird): return key(.f, controlOption, on: thirdsOn)
        case (_, .lastThird): return key(.g, controlOption, on: thirdsOn)
        case (_, .firstTwoThirds): return key(.e, controlOption, on: thirdsOn)
        case (_, .centerTwoThirds): return key(.r, controlOption, on: thirdsOn)
        case (_, .lastTwoThirds): return key(.t, controlOption, on: thirdsOn)
        case (_, .maximize): return key(.return, controlOption)
        case (_, .center): return key(.c, controlOption)
        case (_, .restore): return key(.delete, controlOption)
        case (_, .nextDisplay): return key(.right, hyper)
        case (_, .previousDisplay): return key(.left, hyper)
        }
    }

    /// The keys presets use: virtual key code (`kVK_*`) and the name shown for it.
    private enum Key {
        case left, right, up, down, `return`, delete
        case c, d, e, f, g, i, j, k, r, t, u

        var code: UInt32 {
            switch self {
            case .left: 123
            case .right: 124
            case .down: 125
            case .up: 126
            case .return: 36
            case .delete: 51
            case .c: 8
            case .d: 2
            case .e: 14
            case .f: 3
            case .g: 5
            case .i: 34
            case .j: 38
            case .k: 40
            case .r: 15
            case .t: 17
            case .u: 32
            }
        }

        var name: String {
            switch self {
            case .left: "←"
            case .right: "→"
            case .up: "↑"
            case .down: "↓"
            case .return: "↩"
            case .delete: "⌫"
            default: "\(self)".uppercased()
            }
        }
    }
}
