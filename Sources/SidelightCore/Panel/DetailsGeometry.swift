import CoreGraphics

/// Where the details panel goes: the full height of its display's visible frame, on the side panel's edge, or on
/// the left when it stands in for a bar.
///
/// All rects use Cocoa screen coordinates.
public enum DetailsGeometry {
    /// The same on every display and for every widget, so details are designed once. Narrower only on a screen
    /// that can't fit it.
    public static let width: CGFloat = 360

    /// The edge the details panel opens on, in place of a panel at `position`.
    public static func edge(replacing position: PanelPosition) -> PanelPosition {
        position == .right ? .right : .left
    }

    /// The details panel's frame inside `visibleFrame`, in place of a panel at `position`.
    public static func frame(in visibleFrame: CGRect, replacing position: PanelPosition) -> CGRect {
        let width = min(Self.width, visibleFrame.width).rounded(.down)
        let x = edge(replacing: position) == .right ? visibleFrame.maxX - width : visibleFrame.minX
        return CGRect(x: x, y: visibleFrame.minY, width: width, height: visibleFrame.height)
    }
}
