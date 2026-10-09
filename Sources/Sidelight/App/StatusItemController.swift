import AppKit
import SidelightCore

/// The menu bar icon and its menu, rebuilt each time it opens so it always reflects the current state.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let environment: AppEnvironment
    private let panels: PanelCoordinator
    private let windows: WindowCoordinator

    private var store: ConfigurationStore { environment.configurationStore }

    init(environment: AppEnvironment, panels: PanelCoordinator, windows: WindowCoordinator) {
        self.environment = environment
        self.panels = panels
        self.windows = windows
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidelight")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let configuration = store.configuration
        menu.removeAllItems()

        let toggle = NSMenuItem(panels.isHidden ? "Show Panel" : "Hide Panel") { [panels] in panels.toggle() }
        toggle.toolTip = "Global shortcut: \(configuration.hotkey.displayString)"
        menu.addItem(toggle)
        menu.addItem(NSMenuItem("Widgets…") { [windows] in windows.show(.manager) })
        menu.addItem(NSMenuItem("Settings…") { [windows] in windows.show(.settings) })
        menu.addItem(.separator())

        if let display = displayUnderMenu() {
            addDisplayItems(for: display, to: menu)
        }
        menu.addItem(
            choiceMenu(
                "Background", BackgroundKind.allCases, selected: configuration.appearance.background.kind,
                title: \.title
            ) {
                [store] in store.configuration.appearance.background.kind = $0
            })
        menu.addItem(
            choiceMenu("Cards", CardStyle.allCases, selected: configuration.appearance.cards.style, title: \.title) {
                [store] in store.configuration.appearance.cards.style = $0
            })
        menu.addItem(
            choiceMenu(
                "Window Avoidance", WindowAvoidanceMode.allCases, selected: configuration.windowAvoidance,
                title: \.title
            ) {
                [store] in store.configuration.windowAvoidance = $0
            }
        )
        menu.addItem(.separator())

        let avoider = environment.windowAvoider
        menu.addItem(NSMenuItem("Move Overlapping Windows Now") { avoider.avoidAllWindows() })
        if !avoider.isTrusted {
            menu.addItem(NSMenuItem("Grant Accessibility Access…") { avoider.requestAccess() })
        }
        let rectangle = environment.rectangle
        menu.addItem(
            NSMenuItem("Configure Rectangle for Panel…") { [store, environment] in
                rectangle.configure(for: store.configuration, displays: environment.displays.displays)
            })
        menu.addItem(NSMenuItem("Revert Rectangle Configuration…") { rectangle.revert() })
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sidelight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// The display whose menu bar the menu was opened from.
    private func displayUnderMenu() -> Display? {
        let monitor = environment.displays
        guard let screen = statusItem.button?.window?.screen, let id = Display(screen, isMain: false)?.id else {
            return monitor.displays.first
        }
        return monitor.display(withID: id) ?? monitor.displays.first
    }

    /// Position, size and visibility of the panel as seen from `display`. A setting the display overrides is
    /// changed for that display only (and the title says so); anything else changes the default for all displays.
    private func addDisplayItems(for display: Display, to menu: NSMenu) {
        let configuration = store.configuration
        let panel = display.panel(in: configuration)
        let profile = configuration.displayProfile(id: display.id)
        let hasSeveralDisplays = environment.displays.displays.count > 1

        func title(_ setting: String, isOverridden: Bool) -> String {
            isOverridden && hasSeveralDisplays ? "\(setting) on \(display.name)" : setting
        }

        menu.addItem(
            choiceMenu(
                title("Position", isOverridden: profile?.position != nil), PanelPosition.allCases,
                selected: panel.position, title: \.title
            ) { [store] position in
                store.configuration.set(position, default: \.position, override: \.position, on: display)
            })

        let sizes = NSMenu()
        for density in WidgetDensity.allCases {
            let points = Int(display.panelWidth(.preset(density)))
            sizes.addItem(
                NSMenuItem("\(density.title) · \(points) pt", isChecked: panel.width == .preset(density)) {
                    [store] in
                    store.configuration.set(.preset(density), default: \.width, override: \.width, on: display)
                })
        }
        if panel.width.preset == nil {
            let custom = NSMenuItem(title: panel.width.title, action: nil, keyEquivalent: "")
            custom.state = .on
            sizes.addItem(custom)
        }
        sizes.addItem(.separator())
        sizes.addItem(NSMenuItem("Custom Size…") { [windows] in windows.show(.settings) })
        let sizeItem = NSMenuItem(
            title: title("Size", isOverridden: profile?.width != nil), action: nil, keyEquivalent: "")
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        menu.addItem(
            choiceMenu(
                title("Length", isOverridden: profile?.length != nil), PanelLength.allCases,
                selected: panel.length, title: \.title
            ) { [store] length in
                store.configuration.set(length, default: \.length, override: \.length, on: display)
            })

        if hasSeveralDisplays || !panel.showsPanel {
            menu.addItem(
                NSMenuItem("Show on \(display.name)", isChecked: panel.showsPanel) { [store] in
                    store.configuration.setShowsPanel(!panel.showsPanel, on: display)
                })
        }
    }

    private func choiceMenu<Value: Equatable>(
        _ title: String,
        _ values: [Value],
        selected: Value,
        title valueTitle: (Value) -> String,
        select: @escaping (Value) -> Void
    ) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        for value in values {
            submenu.addItem(NSMenuItem(valueTitle(value), isChecked: value == selected) { select(value) })
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}
