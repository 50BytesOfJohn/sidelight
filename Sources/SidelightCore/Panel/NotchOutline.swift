import CoreGraphics

/// The outline of a panel joined to its screen edge like the MacBook notch: flush with the edge, with concave
/// shoulders flaring into it at both ends, and rounded corners on the side away from it.
///
/// Rects use view coordinates, with y growing downwards, so a panel joined to the top edge has it at `minY`.
public enum NotchOutline {
    /// - Parameters:
    ///   - rect: The outline's bounds, shoulders included.
    ///   - edge: The screen edge the panel is joined to.
    ///   - cornerRadius: Radius of the two corners away from the edge.
    ///   - shoulder: How far each shoulder reaches along the edge, and how deep it is.
    ///   - isClosed: Whether it also runs along the edge. A hairline drawn around the panel leaves the edge out.
    public static func path(
        in rect: CGRect, edge: PanelPosition, cornerRadius: CGFloat, shoulder: CGFloat, isClosed: Bool = true
    ) -> CGPath {
        // Drawn joined to the top edge, `length` wide and `depth` deep, then turned to `edge`.
        let length = edge.isBar ? rect.width : rect.height
        let depth = edge.isBar ? rect.height : rect.width
        let shoulder = min(max(shoulder, 0), length / 4, depth / 2)
        let body = length - 2 * shoulder
        let radius = min(max(cornerRadius, 0), body / 2, depth - shoulder)

        let path = CGMutablePath()
        path.move(to: .zero)
        path.addArc(
            tangent1End: CGPoint(x: shoulder, y: 0), tangent2End: CGPoint(x: shoulder, y: shoulder), radius: shoulder)
        path.addArc(
            tangent1End: CGPoint(x: shoulder, y: depth), tangent2End: CGPoint(x: length - shoulder, y: depth),
            radius: radius)
        path.addArc(
            tangent1End: CGPoint(x: length - shoulder, y: depth), tangent2End: CGPoint(x: length - shoulder, y: 0),
            radius: radius)
        path.addArc(
            tangent1End: CGPoint(x: length - shoulder, y: 0), tangent2End: CGPoint(x: length, y: 0), radius: shoulder)
        if isClosed { path.closeSubpath() }

        var transform = transform(to: edge, in: rect)
        return path.copy(using: &transform) ?? path
    }

    /// Maps the outline drawn joined to the top edge onto `rect`, joined to `edge`.
    private static func transform(to edge: PanelPosition, in rect: CGRect) -> CGAffineTransform {
        switch edge {
        case .top: CGAffineTransform(translationX: rect.minX, y: rect.minY)
        case .bottom: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: rect.minX, ty: rect.maxY)
        case .left: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: rect.minX, ty: rect.minY)
        case .right: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: rect.maxX, ty: rect.minY)
        }
    }
}
