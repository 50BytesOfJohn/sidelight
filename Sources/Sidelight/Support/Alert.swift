import AppKit

/// Modal alerts for the few flows that need explicit confirmation.
enum Alert {
    /// Returns whether the user chose `confirmTitle`.
    static func confirm(title: String, message: String, confirmTitle: String = "Continue") -> Bool {
        let alert = makeAlert(title: title, message: message)
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func inform(title: String, message: String) {
        let alert = makeAlert(title: title, message: message)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func makeAlert(title: String, message: String) -> NSAlert {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        return alert
    }
}
