import AppKit

/// The main menu. An accessory app still needs one: without an Edit menu, ⌘C/⌘V/⌘A don't reach text fields.
enum MainMenu {
    static func install(windows: WindowCoordinator) {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem("Widgets…", keyEquivalent: "1") { windows.show(.manager) })
        appMenu.addItem(NSMenuItem("Settings…", keyEquivalent: ",") { windows.show(.settings) })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sidelight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(submenuItem(appMenu))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(submenuItem(editMenu))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        mainMenu.addItem(submenuItem(windowMenu))

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

extension NSMenuItem {
    /// A menu item that runs `handler` when chosen, instead of sending a selector to some target.
    convenience init(_ title: String, keyEquivalent: String = "", isChecked: Bool? = nil, handler: @escaping () -> Void)
    {
        let target = MenuItemAction(handler)
        self.init(title: title, action: #selector(MenuItemAction.invoke), keyEquivalent: keyEquivalent)
        self.target = target
        // `target` is a weak reference; the represented object keeps the handler alive as long as the item.
        representedObject = target
        if let isChecked { state = isChecked ? .on : .off }
    }
}

private final class MenuItemAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func invoke() {
        handler()
    }
}
