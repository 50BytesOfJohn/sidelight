import AppKit
import Carbon.HIToolbox
import Observation
import SidelightCore
import os

/// Registers the global "toggle panel" shortcut.
///
/// Uses Carbon's `RegisterEventHotKey`, which (unlike an `NSEvent` global monitor) needs no Accessibility
/// permission and works while the app is in the background.
@Observable
final class HotkeyCenter {
    /// The status of the last failed registration (usually: the shortcut is taken by another app).
    private(set) var registrationError: OSStatus?

    /// Called on the main actor when the shortcut is pressed.
    @ObservationIgnored var onPress: () -> Void = {}

    /// The last shortcut we tried to register, whether or not that worked.
    @ObservationIgnored private var requestedHotkey: Hotkey?
    @ObservationIgnored private var hotKeyReference: EventHotKeyRef?
    @ObservationIgnored private var eventHandler: EventHandlerRef?

    /// 'Sdlt'
    private static let signature: OSType = 0x5364_6C74

    func register(_ hotkey: Hotkey) {
        guard hotkey != requestedHotkey else { return }
        unregister()
        requestedHotkey = hotkey
        installEventHandlerIfNeeded()

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers.rawValue,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
        if status == noErr {
            registrationError = nil
        } else {
            registrationError = status
            Log.app.error("Can't register hotkey \(hotkey.displayString, privacy: .public): status \(status)")
        }
    }

    func unregister() {
        if let hotKeyReference { UnregisterEventHotKey(hotKeyReference) }
        hotKeyReference = nil
        requestedHotkey = nil
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(context).takeUnretainedValue()
            // Let Carbon finish dispatching before reacting.
            Task { @MainActor in center.onPress() }
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
