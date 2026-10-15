import AppKit
import Carbon.HIToolbox
import SidelightCore
import os

/// The last resort for reading a selection Accessibility can't see (apps that draw their own text, like GPUI ones):
/// presses ⌘C in the frontmost app, takes the text it copies, then puts the clipboard back as it was.
///
/// Only when the clipboard can be put back exactly (``ClipboardRestore``): it's left alone otherwise, and the caller
/// says to copy by hand. Clipboard history tools may still notice the copied selection in passing.
enum SelectionCopier {
    enum Outcome {
        case text(String)
        /// The app marked what it copied private, like a password; it isn't read.
        case concealed
        /// The app copied nothing in time: no selection, or ⌘C isn't copy there. The reason is for the log.
        case nothingCopied(String)
        /// Not tried: the reason is for the log, the hint for the person.
        case notTried(String, hint: String)
    }

    /// How long the shortcut's own keys may stay held: ⌘C pressed while they are would be another shortcut.
    private static let modifierReleaseTimeout = Duration.seconds(1)
    /// How long the app may take to copy. Apps answer within a frame or two; one slower than this may still copy
    /// later, and then that copy stays on the clipboard.
    private static let copyTimeout = Duration.seconds(1)
    private static let pollInterval = Duration.milliseconds(15)

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Copies the selection in `app`, which must stay frontmost throughout.
    static func copySelection(in app: NSRunningApplication) async -> Outcome {
        let pasteboard = NSPasteboard.general
        let itemTypes = (pasteboard.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }
        if let type = ClipboardRestore.unrestorableType(in: itemTypes) {
            return .notTried(
                "the clipboard holds \(type), which can't be put back exactly after copying",
                hint: "Sidelight can't copy it without changing what's on the clipboard.")
        }
        guard let snapshot = Snapshot(of: pasteboard) else {
            return .notTried(
                "the clipboard's contents can't all be read, to put back after copying",
                hint: "Sidelight can't copy it without changing what's on the clipboard.")
        }

        let shortcutReleased = await wait(upTo: modifierReleaseTimeout) {
            CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: heldModifiers)
        }
        guard shortcutReleased else {
            return .notTried("the shortcut's keys were held too long", hint: "Release the shortcut's keys sooner.")
        }
        // Switched away while waiting: ⌘C would go to the wrong app, maybe an excluded one or Sidelight.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return .notTried("another app came to the front", hint: "Stay in the app until it's stashed.")
        }

        let before = pasteboard.changeCount
        pressCopy()
        let copied = await wait(upTo: copyTimeout) { pasteboard.changeCount != before }
        guard copied else { return .nothingCopied("⌘C copied nothing within \(copyTimeout)") }
        // The count changes as the app clears the clipboard, a moment before it writes.
        try? await Task.sleep(for: pollInterval)

        let types = pasteboard.types ?? []
        let text = types.contains(concealedType) ? nil : pasteboard.string(forType: .string)
        snapshot.restore(to: pasteboard)
        if types.contains(concealedType) { return .concealed }
        guard let text else { return .nothingCopied("⌘C copied no text") }
        return .text(text)
    }

    /// The modifier keys a shortcut can hold. Caps Lock and Fn don't change ⌘C.
    private static let heldModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    /// Waits until `condition` holds, checking it every ``pollInterval``; whether it did before `timeout`.
    private static func wait(upTo timeout: Duration, until condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: pollInterval)
        }
        return true
    }

    /// Presses ⌘C, as the keyboard would, for the frontmost app. The key is whichever types C with ⌘ held on the
    /// current layout (on Dvorak, it isn't the key labeled C on a US keyboard).
    private static func pressCopy() {
        // A private state, so keys held on the keyboard don't mix into these events.
        let source = CGEventSource(stateID: .privateState)
        let key = copyKeyCode()
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    /// The key that types "c" with ⌘ held on the layout menus use for shortcuts: the current one, or, while one
    /// that doesn't type Latin letters is selected, the Latin one it falls back to.
    private static func copyKeyCode() -> CGKeyCode {
        let standard = CGKeyCode(kVK_ANSI_C)
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return standard }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> CGKeyCode in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return standard
            }
            let commandState = UInt32((cmdKey >> 8) & 0xFF)
            // The usual key first: on most layouts, that's the answer.
            let keys = [standard] + (0..<128).map(CGKeyCode.init).filter { $0 != standard }
            for key in keys {
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, key, UInt16(kUCKeyActionDown), commandState, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters)
                if status == noErr, String(utf16CodeUnits: characters, count: length) == "c" { return key }
            }
            return standard
        }
    }

    /// Everything on the clipboard, every item in every type, to write back as it was.
    private struct Snapshot {
        let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]

        /// `nil` when some of it can't be read.
        init?(of pasteboard: NSPasteboard) {
            var items: [[(type: NSPasteboard.PasteboardType, data: Data)]] = []
            for item in pasteboard.pasteboardItems ?? [] {
                var representations: [(type: NSPasteboard.PasteboardType, data: Data)] = []
                var unreadable: [String] = []
                for type in item.types {
                    if let data = item.data(forType: type) {
                        representations.append((type, data))
                    } else {
                        unreadable.append(type.rawValue)
                    }
                }
                let readable = representations.map(\.type.rawValue)
                guard unreadable.allSatisfy({ ClipboardRestore.canOmitUnreadable($0, besideReadable: readable) })
                else { return nil }
                items.append(representations)
            }
            self.items = items
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            guard !items.isEmpty else { return }
            let restored = items.map { representations in
                let item = NSPasteboardItem()
                for (type, data) in representations { item.setData(data, forType: type) }
                return item
            }
            if !pasteboard.writeObjects(restored) {
                Log.stash.error("Couldn't put the clipboard back after copying the selection")
            }
        }
    }
}
