import Cocoa
import SwiftUI

/// Manager + Settings windows for an LSUIElement (accessory) app.
/// What's needed for them to come to the front and take typing:
///  1. switch to `.regular` activation policy while any of them is open (gives a Dock icon + Cmd-Tab entry),
///  2. `NSApp.activate()` then `makeKeyAndOrderFront`,
///  3. a main menu with an Edit menu, otherwise ⌘C/⌘V/⌘A don't work in text fields,
///  4. back to `.accessory` after the last one closes, and drop the SwiftUI tree so memory is returned.
final class WindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = WindowCoordinator()
    private(set) var manager: NSWindow?
    private(set) var settings: NSWindow?

    func showManager() {
        if manager == nil {
            manager = make(title: "Widgets", size: NSSize(width: 1180, height: 760), min: NSSize(width: 1040, height: 640),
                           autosave: "WidgetsWindow", root: ManagerView())
        }
        present(manager!)
    }

    func showSettings() {
        if settings == nil {
            settings = make(title: "SidePanel Settings", size: NSSize(width: 620, height: 760), min: NSSize(width: 560, height: 520),
                            autosave: "SettingsWindow", root: SettingsView())
        }
        present(settings!)
    }

    func closeManager() { manager?.performClose(nil); manager?.close() }

    private func make<V: View>(title: String, size: NSSize, min: NSSize, autosave: String, root: V) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = min
        w.contentView = NSHostingView(rootView: root)
        w.center()
        w.setFrameAutosaveName(autosave)
        w.delegate = self
        w.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        return w
    }

    private func present(_ w: NSWindow) {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        // macOS 14+ cooperative activation: plain activate() is refused when nobody yields (e.g. launched in the
        // background). The deprecated ignoringOtherApps: variant still forces it (tested on macOS 27).
        if UserDefaults.standard.bool(forKey: "cooperativeActivateOnly") { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            appendLog("launch.log", "window '\(w.title)': appActive=\(NSApp.isActive) isKey=\(w.isKeyWindow) isMain=\(w.isMainWindow) policy=\(NSApp.activationPolicy().rawValue) firstResponder=\(String(describing: w.firstResponder.map { type(of: $0) }))")
        }
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow else { return }
        DispatchQueue.main.async {
            w.contentView = nil            // release the SwiftUI tree (and any previews)
            if w === self.manager { self.manager = nil }
            if w === self.settings { self.settings = nil }
            if self.manager == nil && self.settings == nil {
                NSApp.setActivationPolicy(.accessory)
                appendLog("launch.log", "all windows closed: policy=\(NSApp.activationPolicy().rawValue) (1 = accessory)")
            }
        }
    }
}
