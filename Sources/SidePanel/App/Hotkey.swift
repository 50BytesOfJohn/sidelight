import Carbon
import AppKit

/// Global hotkey via Carbon RegisterEventHotKey: works without Accessibility permission and in an accessory app.
final class HotkeyManager {
    static let shared = HotkeyManager()
    var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var lastStatus: OSStatus = 0

    func register(_ spec: HotkeySpec) {
        unregister()
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let cb: EventHandlerUPP = { _, _, userData in
                let me = Unmanaged<HotkeyManager>.fromOpaque(userData!).takeUnretainedValue()
                DispatchQueue.main.async { me.action?() }
                return noErr
            }
            InstallEventHandler(GetApplicationEventTarget(), cb, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x53506E6C) /* 'SPnl' */, id: 1)
        lastStatus = RegisterEventHotKey(spec.keyCode, spec.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        appendLog("launch.log", "hotkey \(spec.display) register status=\(lastStatus)\(lastStatus == noErr ? " (ok)" : " (FAILED, maybe taken)")")
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    /// Convert an NSEvent (from the recorder) to a Carbon spec.
    static func spec(from e: NSEvent) -> HotkeySpec? {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard f.contains(.command) || f.contains(.option) || f.contains(.control) else { return nil }
        var mods: UInt32 = 0
        if f.contains(.command) { mods |= UInt32(cmdKey) }
        if f.contains(.option) { mods |= UInt32(optionKey) }
        if f.contains(.control) { mods |= UInt32(controlKey) }
        if f.contains(.shift) { mods |= UInt32(shiftKey) }
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        s += (e.charactersIgnoringModifiers ?? "?").uppercased()
        return HotkeySpec(keyCode: UInt32(e.keyCode), modifiers: mods, display: s)
    }
}
