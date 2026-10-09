import CoreGraphics

/// Where the panel's window goes inside the strip it reserves along its screen edge.
///
/// All rects use Cocoa screen coordinates: y grows upwards, so a side panel aligned to the top keeps its `maxY`.
public enum PanelGeometry {
    /// A fitted panel is never shorter than this, so it doesn't vanish without widgets.
    public static let minimumLength: CGFloat = 60

    /// The window's frame: the whole strip, or for ``PanelLength/fit`` a part of it `contentLength` long (within
    /// `minimumLength` and the strip's length), aligned along the edge.
    public static func frame(
        inStrip strip: CGRect,
        position: PanelPosition,
        length: PanelLength,
        alignment: PanelAlignment,
        contentLength: CGFloat,
        minimumLength: CGFloat = minimumLength
    ) -> CGRect {
        guard length == .fit else { return strip }
        let available = position.isBar ? strip.width : strip.height
        let fitted = min(max(contentLength.rounded(.up), minimumLength), available)
        let slack = available - fitted

        if position.isBar {
            let offset: CGFloat =
                switch alignment {
                case .start: 0
                case .center: (slack / 2).rounded()
                case .end: slack
                }
            return CGRect(x: strip.minX + offset, y: strip.minY, width: fitted, height: strip.height)
        } else {
            // Start is the top, which in Cocoa coordinates is the far end of the y axis.
            let offset: CGFloat =
                switch alignment {
                case .start: slack
                case .center: (slack / 2).rounded()
                case .end: 0
                }
            return CGRect(x: strip.minX, y: strip.minY + offset, width: strip.width, height: fitted)
        }
    }
}
