import AppKit
import SidelightCore

/// One display as everything that moves a window sees it: in Accessibility space, with where windows may go on it.
struct DisplayArea {
    let id: Display.ID
    /// The display's whole frame.
    let frame: CGRect
    /// The display's whole frame in Cocoa space. A frame remembered on a display means nothing once this changes.
    let cocoaFrame: CGRect
    /// Without the menu bar and the Dock.
    let visibleFrame: CGRect
    /// Where windows may go on it (see ``WorkArea``).
    let workArea: WorkArea
    /// Thirds run along a display's long side, so which way it's turned changes the tiles.
    let isPortrait: Bool
}

/// The connected displays with where windows may go on each, built once from the panels' strips.
///
/// The `NSScreen.primary` height lookup and the Cocoa→Accessibility conversion live here, so the window manager,
/// window avoidance and Sidelight's own windows all read one geometry instead of each deriving it.
enum ScreenLayout {
    /// The height Cocoa and Accessibility coordinates are flipped around; `nil` with no screens.
    static var primaryScreenHeight: CGFloat? { NSScreen.primary?.frame.height }

    /// The connected displays, with each one's work area for `regions`. `padding` is the window manager's; every
    /// other caller leaves its tiles' spacing out of it.
    static func areas(
        regions: [PanelRegion], padding: CGFloat = 0, among displays: [Display] = Display.connected()
    ) -> [DisplayArea] {
        guard let height = primaryScreenHeight else { return [] }
        return displays.map { display in
            let visibleFrame = AvoidanceGeometry.accessibilityRect(
                fromCocoa: display.visibleFrame, primaryScreenHeight: height)
            return DisplayArea(
                id: display.id,
                frame: AvoidanceGeometry.accessibilityRect(fromCocoa: display.frame, primaryScreenHeight: height),
                cocoaFrame: display.frame,
                visibleFrame: visibleFrame,
                workArea: WorkArea(
                    visibleFrame: visibleFrame,
                    reservations: regions.filter { $0.displayID == display.id }
                        .map { $0.reservation(primaryScreenHeight: height) },
                    padding: padding),
                isPortrait: display.frame.height > display.frame.width)
        }
    }

    /// The display `frame` is on: the one holding most of it (see ``WindowLayout/sourceDisplay(of:among:)``).
    static func display(of frame: CGRect, among areas: [DisplayArea]) -> DisplayArea? {
        WindowLayout.sourceDisplay(of: frame, among: areas.map(\.frame)).map { areas[$0] }
    }
}

extension PanelRegion {
    /// This strip in Accessibility space.
    func reservation(primaryScreenHeight: CGFloat) -> Reservation {
        Reservation(
            frame: AvoidanceGeometry.accessibilityRect(fromCocoa: frame, primaryScreenHeight: primaryScreenHeight),
            edge: edge, role: role)
    }
}
