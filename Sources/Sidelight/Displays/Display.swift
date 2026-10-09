import AppKit
import CoreGraphics
import Observation
import SidelightCore

/// A connected screen, identified by its Core Graphics UUID so its panel settings survive reconnects and
/// reboots (display IDs and `NSScreen` order don't).
struct Display: Identifiable, Equatable {
    let id: String
    let name: String
    /// The screen with the menu bar, which shows the panel unless configured otherwise.
    let isMain: Bool
    let isBuiltIn: Bool
    /// In Cocoa screen coordinates.
    let frame: CGRect
    let visibleFrame: CGRect

    init?(_ screen: NSScreen, isMain: Bool) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            id = CFUUIDCreateString(nil, uuid) as String
        } else {
            id = "display-\(displayID)"
        }
        name = screen.localizedName
        self.isMain = isMain
        isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
        frame = screen.frame
        visibleFrame = screen.visibleFrame
    }

    /// Connected displays, main display first.
    static func connected() -> [Display] {
        NSScreen.screens.enumerated().compactMap { index, screen in Display(screen, isMain: index == 0) }
    }

    /// The panel on this display: the defaults with its overrides applied.
    func panel(in configuration: AppConfiguration) -> DisplayPanel {
        configuration.panel(onDisplay: id, isMain: isMain)
    }

    /// The side panel's width on this display.
    func panelWidth(_ width: PanelWidth) -> CGFloat {
        CGFloat(width.points(screenWidth: frame.width))
    }

    var systemImage: String { isBuiltIn ? "laptopcomputer" : "display" }
}

extension AppConfiguration {
    /// Edits the overrides of a connected display.
    mutating func updateProfile(of display: Display, _ change: (inout DisplayProfile) -> Void) {
        updateDisplayProfile(id: display.id, name: display.name, change)
    }

    /// Changes a setting as seen from `display`: its own override if it has one, otherwise the default.
    mutating func set<Value>(
        _ value: Value,
        default defaultKeyPath: WritableKeyPath<PanelDefaults, Value>,
        override overrideKeyPath: WritableKeyPath<DisplayProfile, Value?>,
        on display: Display
    ) {
        set(value, default: defaultKeyPath, override: overrideKeyPath, onDisplay: display.id, name: display.name)
    }

    mutating func setShowsPanel(_ showsPanel: Bool, on display: Display) {
        setShowsPanel(showsPanel, onDisplay: display.id, name: display.name, isMain: display.isMain)
    }
}

/// The connected displays, kept current as screens are attached, detached, rearranged or change resolution.
@Observable
final class DisplayMonitor {
    private(set) var displays = Display.connected()

    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func display(withID id: Display.ID) -> Display? {
        displays.first { $0.id == id }
    }

    private func refresh() {
        let connected = Display.connected()
        if connected != displays { displays = connected }
    }
}
