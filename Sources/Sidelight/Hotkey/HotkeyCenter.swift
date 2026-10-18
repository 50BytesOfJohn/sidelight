import AppKit
import Carbon.HIToolbox
import Observation
import SidelightCore
import os

/// What a global shortcut does.
enum HotkeyAction: Hashable, CaseIterable {
    /// Shows or hides the panels, and the details panel with them. Registered all the time.
    case togglePanels
    /// Closes the details panel. Registered only while one is open, so it takes nothing from other apps otherwise.
    case closeDetails
    /// Stashes the frontmost app's selected text. Registered only while a Stash widget is in the configuration.
    case stashSelection
    /// Stashes the clipboard's text. Registered only while a Stash widget is in the configuration.
    case stashClipboard
    /// Moves or resizes the frontmost window. Registered only while the window manager is on.
    case window(WindowAction)

    /// In the order shortcuts are registered: an earlier action wins a shortcut two share. The panel's and the
    /// stash's come before the window manager's.
    static let allCases: [HotkeyAction] =
        [.togglePanels, .closeDetails, .stashSelection, .stashClipboard] + WindowAction.allCases.map(Self.window)

    /// The identifier Carbon reports a press with: 1 to 4 for the panel's and the stash's, then 100 on for the window
    /// manager's, in ``WindowAction`` order.
    var carbonID: UInt32 {
        switch self {
        case .togglePanels: 1
        case .closeDetails: 2
        case .stashSelection: 3
        case .stashClipboard: 4
        case .window(let action): 100 + UInt32(WindowAction.allCases.firstIndex(of: action) ?? 0)
        }
    }

    init?(carbonID: UInt32) {
        guard let action = Self.allCases.first(where: { $0.carbonID == carbonID }) else { return nil }
        self = action
    }

    /// What the log calls it.
    var logName: String {
        switch self {
        case .togglePanels: "show or hide"
        case .closeDetails: "close details"
        case .stashSelection: "stash selection"
        case .stashClipboard: "stash clipboard"
        case .window(let action): "window \(action.rawValue)"
        }
    }
}

/// Why a shortcut isn't working.
enum HotkeyProblem: Equatable {
    /// macOS refused it (the status from `RegisterEventHotKey`); `eventHotKeyExistsErr` when another app has taken
    /// it exclusively.
    case unavailable(OSStatus)
    /// Another of Sidelight's shortcuts is the same, and goes first.
    case sameAs(HotkeyAction)
}

/// Registers Sidelight's global shortcuts, each for its own action.
///
/// Uses Carbon's `RegisterEventHotKey`, which (unlike an `NSEvent` global monitor) needs no Accessibility
/// permission and works while the app is in the background.
@Observable
final class HotkeyCenter {
    /// Why each shortcut that isn't working as asked isn't.
    private(set) var problems: [HotkeyAction: HotkeyProblem] = [:]

    /// Called on the main actor when an action's shortcut is pressed.
    @ObservationIgnored var handlers: [HotkeyAction: () -> Void] = [:]

    /// The shortcut each action should have, whether or not that worked.
    @ObservationIgnored private var requested: [HotkeyAction: Hotkey] = [:]
    /// Observed, so settings showing ``workingHotkey(for:)`` follow a shortcut being taken or given back.
    private var registered: [HotkeyAction: (hotkey: Hotkey, reference: EventHotKeyRef)] = [:]
    /// The shortcut that last registered for each action, kept while recording frees them all and while a new one is
    /// refused: it's what the action falls back to. Forgotten only when the action's shortcut is taken away.
    @ObservationIgnored private var lastWorking: [HotkeyAction: Hotkey] = [:]
    /// While a shortcut is being recorded, none is registered, so pressing one reaches the recorder.
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var eventHandler: EventHandlerRef?

    /// 'Sdlt'
    private nonisolated static let signature: OSType = 0x5364_6C74

    /// Gives `action` the shortcut `hotkey`, replacing the one it had; one that's turned off takes it away. Asking
    /// again for one that didn't work tries again.
    func register(_ hotkey: Hotkey, for action: HotkeyAction) {
        register([(action, hotkey)])
    }

    /// Gives each action its shortcut, as ``register(_:for:)`` does, then registers them all in one go.
    func register(_ bindings: [(action: HotkeyAction, hotkey: Hotkey)]) {
        var changed = false
        for (action, hotkey) in bindings {
            guard hotkey.isEnabled else {
                changed = forget(action) || changed
                continue
            }
            guard requested[action] != hotkey || problems[action] != nil else { continue }
            requested[action] = hotkey
            changed = true
        }
        if changed { reconcile() }
    }

    /// Takes `action`'s shortcut away, with what it would fall back to.
    func unregister(_ action: HotkeyAction) {
        unregister([action])
    }

    /// Takes each action's shortcut away, in one go.
    func unregister(_ actions: [HotkeyAction]) {
        let changed = actions.reduce(false) { forget($1) || $0 }
        if changed { reconcile() }
    }

    /// Forgets `action`'s shortcut; whether it had one.
    private func forget(_ action: HotkeyAction) -> Bool {
        guard requested[action] != nil else { return false }
        requested[action] = nil
        lastWorking[action] = nil
        return true
    }

    /// Frees every shortcut while a new one is recorded.
    func suspend() {
        isSuspended = true
        reconcile()
    }

    /// Registers the shortcuts again after recording.
    func resume() {
        isSuspended = false
        reconcile()
    }

    /// The shortcut that works for `action` right now, which may still be its earlier one when the one asked for
    /// couldn't be registered; `nil` for none.
    func workingHotkey(for action: HotkeyAction) -> Hotkey? {
        registered[action]?.hotkey
    }

    /// Brings the registrations in line with what's requested, in two steps: first every registration of Sidelight's
    /// that doesn't fit the new mapping is released, so a shortcut moving from one action to another (or two
    /// swapping) is free to take; then what's missing is registered, in ``HotkeyAction`` order. An action whose
    /// shortcut an earlier one already has gets none, so pressing it does one thing. When macOS refuses a new
    /// shortcut, an action that had a working one gets it back, even after recording freed it, so the toggle never
    /// stops working over a shortcut another app has. A fallback another action now uses isn't taken.
    private func reconcile() {
        installEventHandlerIfNeeded()
        var desired: [(action: HotkeyAction, hotkey: Hotkey)] = []
        for action in HotkeyAction.allCases {
            guard !isSuspended, let hotkey = requested[action] else {
                setProblem(nil, for: action)
                continue
            }
            if let owner = desired.first(where: { $0.hotkey.isSameShortcut(as: hotkey) }) {
                setProblem(.sameAs(owner.action), for: action)
                continue
            }
            desired.append((action, hotkey))
        }

        for (action, registration) in registered {
            let wanted = desired.first { $0.action == action }?.hotkey
            guard wanted.map({ !$0.isSameShortcut(as: registration.hotkey) }) ?? true else { continue }
            release(action)
        }

        for (action, hotkey) in desired where registered[action] == nil {
            let status = acquire(hotkey, for: action)
            guard status != noErr else {
                setProblem(nil, for: action)
                continue
            }
            if problems[action] != .unavailable(status) {
                let why = status == eventHotKeyExistsErr ? "another app has taken it exclusively" : "status \(status)"
                Log.app.error(
                    """
                    Can't register hotkey \(hotkey.displayString, privacy: .public) for \
                    \(action.logName, privacy: .public): \(why, privacy: .public)
                    """)
            }
            setProblem(.unavailable(status), for: action)
            // Back to the shortcut that worked, unless it's the one refused or another action wants or has it.
            if let fallback = lastWorking[action], !fallback.isSameShortcut(as: hotkey),
                !desired.contains(where: { $0.action != action && $0.hotkey.isSameShortcut(as: fallback) }),
                !registered.values.contains(where: { $0.hotkey.isSameShortcut(as: fallback) })
            {
                _ = acquire(fallback, for: action)
            }
        }
    }

    /// Registers `hotkey` for `action`; returns Carbon's status.
    ///
    /// Shared registrations (no options) let several apps have the same shortcut, each told when it's pressed. But
    /// one app can take a shortcut exclusively, and then every shared registration still succeeds yet is never told:
    /// the shortcut would look fine and do nothing. So it's first asked for exclusively, which fails only against an
    /// exclusive owner (`eventHotKeyExistsErr`), then given back and registered shared, so Sidelight never takes a
    /// shortcut from the apps sharing it. An app that takes it exclusively later can't be noticed.
    private func acquire(_ hotkey: Hotkey, for action: HotkeyAction) -> OSStatus {
        let identifier = EventHotKeyID(signature: Self.signature, id: action.carbonID)
        func register(options: UInt32) -> (status: OSStatus, reference: EventHotKeyRef?) {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                hotkey.keyCode, hotkey.modifiers.rawValue, identifier, GetApplicationEventTarget(), options, &reference)
            return (status, reference)
        }
        let probe = register(options: UInt32(kEventHotKeyExclusive))
        if probe.status == eventHotKeyExistsErr { return probe.status }
        if let reference = probe.reference { UnregisterEventHotKey(reference) }

        let (status, reference) = register(options: 0)
        guard status == noErr, let reference else { return status == noErr ? OSStatus(eventInternalErr) : status }
        registered[action] = (hotkey, reference)
        lastWorking[action] = hotkey
        Log.app.debug(
            "Registered hotkey \(hotkey.displayString, privacy: .public) for \(action.logName, privacy: .public)")
        return noErr
    }

    private func release(_ action: HotkeyAction) {
        held.remove(action)
        guard let registration = registered.removeValue(forKey: action) else { return }
        UnregisterEventHotKey(registration.reference)
        Log.app.debug(
            "Released hotkey \(registration.hotkey.displayString, privacy: .public) for \(action.logName, privacy: .public)"
        )
    }

    private func setProblem(_ problem: HotkeyProblem?, for action: HotkeyAction) {
        if problems[action] != problem { problems[action] = problem }
    }

    /// Window actions whose keys are down: a held shortcut acts once, whether or not Carbon repeats the press.
    @ObservationIgnored private var held: Set<HotkeyAction> = []

    private func pressed(_ identifier: UInt32) {
        guard let action = HotkeyAction(carbonID: identifier) else { return }
        if case .window = action {
            guard held.insert(action).inserted else { return }
        }
        // So `log stream` shows the key arrived, whatever the action then does.
        Log.app.info("Hotkey pressed for \(action.logName, privacy: .public)")
        guard let handler = handlers[action] else {
            return Log.app.error("No handler for the \(action.logName, privacy: .public) hotkey")
        }
        handler()
    }

    private func released(_ identifier: UInt32) {
        guard let action = HotkeyAction(carbonID: identifier) else { return }
        held.remove(action)
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let handler: EventHandlerUPP = { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == HotkeyCenter.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(context).takeUnretainedValue()
            let id = identifier.id
            let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            // Let Carbon finish dispatching before reacting.
            Task { @MainActor in isPress ? center.pressed(id) : center.released(id) }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }
}

extension Hotkey {
    /// The shortcut for a key press in the recorder, or `nil` without ⌘, ⌥ or ⌃.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        let key =
            Self.specialKeyNames[Int(event.keyCode)]
            ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key)
        guard isValid else { return nil }
    }

    /// Keys whose character is invisible or ambiguous.
    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}
