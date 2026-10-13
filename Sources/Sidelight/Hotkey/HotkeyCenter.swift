import AppKit
import Carbon.HIToolbox
import Observation
import SidelightCore
import os

/// What a global shortcut does.
enum HotkeyAction: UInt32, CaseIterable {
    /// Shows or hides the panels, and the details panel with them. Registered all the time.
    case togglePanels = 1
    /// Closes the details panel. Registered only while one is open, so it takes nothing from other apps otherwise.
    case closeDetails = 2
}

/// Why a shortcut isn't working.
enum HotkeyProblem: Equatable {
    /// macOS refused it, usually because another app uses it (the status from `RegisterEventHotKey`).
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
    /// Why each shortcut that isn't working isn't.
    private(set) var problems: [HotkeyAction: HotkeyProblem] = [:]

    /// Called on the main actor when an action's shortcut is pressed.
    @ObservationIgnored var handlers: [HotkeyAction: () -> Void] = [:]

    /// The shortcut each action should have, whether or not that worked.
    @ObservationIgnored private var requested: [HotkeyAction: Hotkey] = [:]
    @ObservationIgnored private var registered: [HotkeyAction: (hotkey: Hotkey, reference: EventHotKeyRef)] = [:]
    /// While a shortcut is being recorded, none is registered, so pressing one reaches the recorder.
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var eventHandler: EventHandlerRef?

    /// 'Sdlt'
    private nonisolated static let signature: OSType = 0x5364_6C74

    /// Gives `action` the shortcut `hotkey`, replacing the one it had.
    func register(_ hotkey: Hotkey, for action: HotkeyAction) {
        guard requested[action] != hotkey else { return }
        requested[action] = hotkey
        reconcile()
    }

    /// Takes `action`'s shortcut away.
    func unregister(_ action: HotkeyAction) {
        guard requested[action] != nil else { return }
        requested[action] = nil
        reconcile()
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

    /// Registers what's requested and isn't yet, in ``HotkeyAction`` order: an action whose shortcut an earlier one
    /// already has gets none, so pressing it does one thing, and the toggle never stops working.
    private func reconcile() {
        installEventHandlerIfNeeded()
        var claimed: [Hotkey: HotkeyAction] = [:]
        for action in HotkeyAction.allCases {
            guard let hotkey = requested[action], !isSuspended else {
                release(action)
                setProblem(nil, for: action)
                continue
            }
            if let owner = claimed[hotkey] {
                release(action)
                setProblem(.sameAs(owner), for: action)
                continue
            }
            claimed[hotkey] = action
            if registered[action]?.hotkey == hotkey { continue }
            release(action)

            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            let status = RegisterEventHotKey(
                hotkey.keyCode,
                hotkey.modifiers.rawValue,
                identifier,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                registered[action] = (hotkey, reference)
                setProblem(nil, for: action)
            } else {
                if problems[action] != .unavailable(status) {
                    Log.app.error("Can't register hotkey \(hotkey.displayString, privacy: .public): status \(status)")
                }
                setProblem(.unavailable(status), for: action)
            }
        }
    }

    private func release(_ action: HotkeyAction) {
        guard let registration = registered.removeValue(forKey: action) else { return }
        UnregisterEventHotKey(registration.reference)
    }

    private func setProblem(_ problem: HotkeyProblem?, for action: HotkeyAction) {
        if problems[action] != problem { problems[action] = problem }
    }

    private func pressed(_ identifier: UInt32) {
        guard let action = HotkeyAction(rawValue: identifier) else { return }
        handlers[action]?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
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
            // Let Carbon finish dispatching before reacting.
            Task { @MainActor in center.pressed(id) }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
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
