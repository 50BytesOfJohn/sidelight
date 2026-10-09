import AppKit
import Observation
import SidelightCore

/// The menu bar icon and its menu, rebuilt each time it opens so it always reflects the current state.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let environment: AppEnvironment
    private let panels: PanelCoordinator
    private let windows: WindowCoordinator
    private var observation: Task<Void, Never>?

    private var store: ConfigurationStore { environment.configurationStore }

    init(environment: AppEnvironment, panels: PanelCoordinator, windows: WindowCoordinator) {
        self.environment = environment
        self.panels = panels
        self.windows = windows
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        observeAvailableUpdate()
    }

    deinit {
        observation?.cancel()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let configuration = store.configuration
        menu.removeAllItems()

        let updater = environment.updater
        if let version = updater.availableVersion {
            menu.addItem(NSMenuItem("Update to Sidelight \(version)…") { updater.checkForUpdates() })
            menu.addItem(.separator())
        }

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
        // An item without an action is disabled.
        menu.addItem(
            updater.canCheckForUpdates
                ? NSMenuItem("Check for Updates…") { updater.checkForUpdates() }
                : NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: ""))
        menu.addItem(withTitle: "Quit Sidelight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// Badges the icon while a background check has found an update the user hasn't seen.
    private func observeAvailableUpdate() {
        let updater = environment.updater
        observation = Task { [weak self] in
            for await hasUpdate in Observations({ updater.availableVersion != nil }) {
                self?.statusItem.button?.image = Self.icon(badged: hasUpdate)
            }
        }
    }

    private static func icon(badged: Bool) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidelight") else {
            return nil
        }
        guard badged else { return symbol }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            let diameter = (rect.height * 0.5).rounded()
            let dot = NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter, width: diameter, height: diameter)
            // Cut a gap around the dot so it reads as a badge on top of the symbol.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Sidelight, update available"
        return image
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
