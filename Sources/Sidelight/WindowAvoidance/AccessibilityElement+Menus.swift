import ApplicationServices
import SidelightCore

/// Reading and pressing an app's menu bar items, off the main actor: reading a whole menu bar takes 50–110 ms, and a
/// busy app up to ``AccessibilityElement/messagingTimeout`` for each call.
extension AccessibilityElement {
    /// Every item in the menu bar of the app with process `pid`, and in their submenus one level down, with the
    /// indexes that find each again. Empty without Accessibility access, or when the app doesn't answer.
    nonisolated static func menuItems(ofProcess pid: pid_t) -> [MenuItemInfo] {
        guard let bar = menuBar(ofProcess: pid) else { return [] }
        var items: [MenuItemInfo] = []
        func walk(_ menu: AXUIElement, path: [Int], depth: Int) {
            for (index, item) in children(of: menu).enumerated() {
                let path = path + [index]
                let title: String = value(item, kAXTitleAttribute) ?? ""
                if !title.isEmpty {
                    items.append(
                        MenuItemInfo(
                            title: title, commandKey: value(item, kAXMenuItemCmdCharAttribute),
                            modifiers: value(item, kAXMenuItemCmdModifiersAttribute) ?? 0,
                            isEnabled: value(item, kAXEnabledAttribute) ?? false, path: path))
                }
                if depth < 2, let submenu = children(of: item).first {
                    walk(submenu, path: path, depth: depth + 1)
                }
            }
        }
        for (index, barItem) in children(of: bar).enumerated() {
            guard let menu = children(of: barItem).first else { continue }
            walk(menu, path: [index], depth: 1)
        }
        return items
    }

    /// Presses the menu item at `path` (see ``menuItems(ofProcess:)``) in the app with process `pid`. Returns whether
    /// the app took it.
    nonisolated static func pressMenuItem(ofProcess pid: pid_t, at path: [Int]) -> Bool {
        guard var element = menuBar(ofProcess: pid), let first = path.first else { return false }
        let barItems = children(of: element)
        guard barItems.indices.contains(first), let menu = children(of: barItems[first]).first else { return false }
        element = menu
        for (position, index) in path.dropFirst().enumerated() {
            let items = children(of: element)
            guard items.indices.contains(index) else { return false }
            let item = items[index]
            if position == path.count - 2 {
                return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
            }
            guard let submenu = children(of: item).first else { return false }
            element = submenu
        }
        return false
    }

    private nonisolated static func menuBar(ofProcess pid: pid_t) -> AXUIElement? {
        value(AXUIElementCreateApplication(pid), kAXMenuBarAttribute)
    }

    private nonisolated static func children(of element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) ?? []
    }

    private nonisolated static func value<Value>(_ element: AXUIElement, _ name: String) -> Value? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Value
    }
}
