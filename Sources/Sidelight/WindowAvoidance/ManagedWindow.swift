import AppKit
import SidelightCore

/// One of Sidelight's own windows, held weakly so a closed one goes away.
struct OwnWindow {
    weak var window: NSWindow?
    /// Whether a move is animated. Sidelight's own windows glide out from under a panel that moved or grew, and snap
    /// into a window manager tile like any other app's.
    var animates = false
}

/// A window Sidelight can place: another app's, through Accessibility, or one of Sidelight's own, directly.
///
/// The shared identity for every feature that moves a window, so one registry can hold them all (see
/// ``WindowPlacer``). Frames are in Accessibility space, whichever kind of window it is.
enum ManagedWindow {
    /// Process identifiers are reused: a window of a later process with the same one isn't this window.
    case other(AccessibilityElement, pid: pid_t, launchDate: Date?)
    case own(OwnWindow)

    var processIdentifier: pid_t? {
        switch self {
        case .other(_, let pid, _): pid
        case .own: nil
        }
    }

    /// Whether this window still exists at all: a closed one of Sidelight's own doesn't.
    var exists: Bool {
        switch self {
        case .other: true
        case .own(let own): own.window != nil
        }
    }

    func isSame(as other: ManagedWindow) -> Bool {
        switch (self, other) {
        case (.other(let element, let pid, let launchDate), .other(let otherElement, let otherPID, let otherLaunch)):
            pid == otherPID && launchDate == otherLaunch && element.isSameElement(as: otherElement)
        case (.own(let window), .own(let otherWindow)):
            window.window != nil && window.window === otherWindow.window
        default:
            false
        }
    }

    /// In Accessibility space.
    var frame: CGRect? {
        switch self {
        case .other(let element, _, _): element.frame
        case .own(let own): own.window.flatMap { Self.accessibility($0.frame) }
        }
    }

    var isPositionSettable: Bool {
        switch self {
        case .other(let element, _, _): element.isPositionSettable
        case .own(let own): own.window != nil
        }
    }

    var isSizeSettable: Bool {
        switch self {
        case .other(let element, _, _): element.isSizeSettable
        case .own(let own): own.window?.styleMask.contains(.resizable) ?? false
        }
    }

    /// Whether a whole frame goes in one write, so no intermediate frame is ever on screen. True for Sidelight's own
    /// windows: `NSWindow.setFrame(_:display:)` is atomic, and only other apps' windows need ``PlacementOrder``.
    var takesWholeFrames: Bool {
        switch self {
        case .other: false
        case .own: true
        }
    }

    /// Writes one half of the frame, for another app's window.
    func write(_ write: FrameWrite) {
        guard case .other(let element, _, _) = self else { return }
        switch write {
        case .position(let point): element.setPosition(point)
        case .size(let size): element.setSize(size)
        }
    }

    /// Puts one of Sidelight's own windows at `frame` in one write; returns the frame it took, `nil` once it's gone.
    func setWholeFrame(_ frame: CGRect) -> CGRect? {
        guard case .own(let own) = self, let window = own.window, var cocoa = Self.accessibility(frame) else {
            return nil
        }
        // AppKit doesn't hold a frame set in code to the window's minimum and maximum sizes, as an app does for an
        // Accessibility resize: so it's sized within them here, and anchored like any other app's.
        let contentMinimum = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize))
        let contentMaximum = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMaxSize))
        let size = WindowLayout.clampedSize(
            cocoa.size,
            minimum: CGSize(
                width: max(window.minSize.width, contentMinimum.width),
                height: max(window.minSize.height, contentMinimum.height)),
            maximum: CGSize(
                width: min(window.maxSize.width, contentMaximum.width),
                height: min(window.maxSize.height, contentMaximum.height)))
        // Kept at the same top edge: Cocoa's origin is the bottom-left.
        cocoa = CGRect(x: cocoa.minX, y: cocoa.maxY - size.height, width: size.width, height: size.height)
        window.setFrame(cocoa, display: true, animate: own.animates && window.isVisible)
        return Self.accessibility(window.frame)
    }

    /// Converts between Cocoa and Accessibility space: the conversion is its own inverse.
    private static func accessibility(_ rect: CGRect) -> CGRect? {
        guard let height = ScreenLayout.primaryScreenHeight else { return nil }
        return AvoidanceGeometry.accessibilityRect(fromCocoa: rect, primaryScreenHeight: height)
    }
}
