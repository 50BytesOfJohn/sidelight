import CoreGraphics

/// Where an overlapping window should go so it no longer sits under the panel.
public struct AvoidancePlan: Equatable, Sendable {
    public enum Action: String, Sendable {
        /// Move the window away from the panel, keeping its size.
        case shift
        /// Keep the window's far edge and shrink it by the overlap.
        case clip
    }

    public var action: Action
    /// Target frame, in the same coordinate space as the inputs.
    public var frame: CGRect
    /// Frame to use instead if the app refuses to shrink to ``frame`` (it enforces a minimum size).
    /// Only set for ``Action/clip``.
    public var shiftFallback: CGRect?
}

/// Pure geometry for window avoidance, independent of the Accessibility API.
///
/// All rects use the Accessibility/Core Graphics global space: origin at the top-left of the primary screen,
/// y growing downwards. The math is written once for a panel on the *left* edge; other edges are mapped into
/// that canonical space (right = mirror x, top = swap axes, bottom = swap axes and mirror) and back.
public enum AvoidanceGeometry {
    /// Space left between the panel and a moved window.
    public static let gap: CGFloat = 8
    /// A window whose near edge is this close to the visible frame's edge counts as snapped.
    static let snapTolerance: CGFloat = 2
    /// Clipping that would leave less than this fraction of the window's width shifts instead.
    static let minimumClipFraction: CGFloat = 0.4

    public static func plan(
        window: CGRect,
        panel: CGRect,
        visibleFrame: CGRect,
        edge: PanelPosition,
        mode: WindowAvoidanceMode
    ) -> AvoidancePlan? {
        guard mode != .off, window.intersects(panel) else { return nil }

        let panel = canonical(panel, edge: edge)
        let window = canonical(window, edge: edge)
        let visible = canonical(visibleFrame, edge: edge)

        let minX = panel.maxX + gap
        let minY = max(window.minY, visible.minY)
        let height = min(window.height, visible.maxY - minY)
        let shifted = CGRect(x: minX, y: minY, width: min(window.width, visible.maxX - minX), height: height)

        let isSnapped = abs(window.minX - visible.minX) <= snapTolerance
        let wantsClip = mode == .clip || (mode == .smart && isSnapped)
        let clippedWidth = window.maxX - minX
        guard wantsClip, clippedWidth >= minimumClipFraction * window.width else {
            return AvoidancePlan(action: .shift, frame: restored(shifted, edge: edge))
        }

        let clipped = CGRect(x: minX, y: minY, width: clippedWidth, height: height)
        return AvoidancePlan(
            action: .clip,
            frame: restored(clipped, edge: edge),
            shiftFallback: restored(shifted, edge: edge)
        )
    }

    /// Whether the app ignored a clip because of its minimum size: the window ended up wider (along the
    /// panel's axis) than requested.
    public static func clipWasRefused(requested: CGRect, actual: CGRect, edge: PanelPosition) -> Bool {
        canonical(actual, edge: edge).width > canonical(requested, edge: edge).width + snapTolerance
    }

    /// Converts a Cocoa rect (bottom-left origin) to Accessibility space (top-left of the primary screen).
    public static func accessibilityRect(fromCocoa rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func canonical(_ rect: CGRect, edge: PanelPosition) -> CGRect {
        switch edge {
        case .left: rect
        case .right: CGRect(x: -rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
        case .top: CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width)
        case .bottom: CGRect(x: -rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        }
    }

    static func restored(_ rect: CGRect, edge: PanelPosition) -> CGRect {
        switch edge {
        case .left: rect
        case .right: CGRect(x: -rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
        case .top: CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width)
        case .bottom: CGRect(x: rect.minY, y: -rect.maxX, width: rect.height, height: rect.width)
        }
    }
}
