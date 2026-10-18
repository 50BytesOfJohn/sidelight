import CoreGraphics

/// Where a window may go on one display.
///
/// The one answer to that question, for every feature that moves a window: the window manager's tiles, window
/// avoidance, and Sidelight's own windows.
///
/// Two rects, for the two different questions:
///
/// - ``rect`` is where a *tile* goes: the visible frame less every panel's ``Reservation/keepOut``, less `padding`
///   along the edges no panel took. Beside a panel the space is the panel's own clearance, whatever the padding
///   says, so a tile, a pushed window and one of Sidelight's own windows all line up on the same line.
/// - ``isClear(_:)`` asks whether a frame covers a panel at all. A window is allowed to sit in the clearance, or
///   reach past the screen's edge — one too big for the room beside a panel has to overhang something. What it may
///   never do is cover the strip, and that's the property a placement's intermediate frames are checked against
///   (see ``PlacementOrder``).
///
/// Every rect is in Accessibility space, as in ``AvoidanceGeometry``: origin at the top-left of the primary screen,
/// y growing downwards.
public struct WorkArea: Sendable, Equatable {
    /// The display's visible frame: without the menu bar and the Dock.
    public let visibleFrame: CGRect
    /// The strips the panels on this display keep clear. Reservations that don't reach the visible frame — a panel on
    /// another display — reserve nothing.
    public let reservations: [Reservation]
    /// What a tile keeps from the edges no panel took.
    public let padding: CGFloat
    /// Where tiles go: ``clear`` less ``padding`` on the edges no panel took.
    public let rect: CGRect
    /// The visible frame with every panel's keep-out taken off, and no padding: where a window belongs.
    public let clear: CGRect

    public init(visibleFrame: CGRect, reservations: [Reservation], padding: CGFloat = 0) {
        self.visibleFrame = visibleFrame
        let inside = reservations.filter { reservation in
            let overlap = reservation.keepOut.intersection(visibleFrame)
            return !overlap.isNull && !overlap.isEmpty
        }
        self.reservations = inside
        self.padding = padding
        rect = Self.remainder(of: visibleFrame, after: inside, padding: padding)
        clear = padding == 0 ? rect : Self.remainder(of: visibleFrame, after: inside, padding: 0)
    }

    /// The whole of `rect`, with nothing reserved: for geometry that has no panel in it.
    public static func unreserved(_ rect: CGRect) -> WorkArea {
        WorkArea(visibleFrame: rect, reservations: [])
    }

    /// Whether `frame` covers no panel's strip. The clearance beside a panel doesn't count: apps round frames, and
    /// nothing is drawn there.
    public func isClear(_ frame: CGRect) -> Bool {
        !reservations.contains { frame.intersects($0.frame) }
    }

    /// Where `frame`, at the size it is, goes so it covers no panel: moved away from each panel it covers in turn,
    /// even if that puts part of it past the screen's edge. `nil` when it already covers none.
    ///
    /// For a window whose app refused the size it was asked for and so kept one too big for the room beside the
    /// panel: it stays as big as it wants, out from under the panel.
    public func clearing(_ frame: CGRect) -> CGRect? {
        var moved = frame
        var didMove = false
        for reservation in reservations {
            guard
                let clear = AvoidanceGeometry.clearing(
                    moved, of: reservation.frame, edge: reservation.edge, clearance: reservation.clearance)
            else { continue }
            moved = clear
            didMove = true
        }
        return didMove ? moved : nil
    }

    /// An origin in ``clear`` where a window of `size` covers no panel, for a move that has to pass through a frame
    /// that big (see ``PlacementOrder``). `nil` when there's no room for it beside the panels.
    public func safeOrigin(for size: CGSize) -> CGPoint? {
        guard size.width <= clear.width, size.height <= clear.height else { return nil }
        return clear.origin
    }

    /// `visibleFrame` with each reservation's keep-out cut off its edge, and `padding` taken from the rest.
    private static func remainder(
        of visibleFrame: CGRect, after reservations: [Reservation], padding: CGFloat
    )
        -> CGRect
    {
        var minX = visibleFrame.minX + padding
        var minY = visibleFrame.minY + padding
        var maxX = visibleFrame.maxX - padding
        var maxY = visibleFrame.maxY - padding
        for reservation in reservations {
            let keepOut = reservation.keepOut
            switch reservation.edge {
            case .left: minX = max(visibleFrame.minX, keepOut.maxX)
            case .right: maxX = min(visibleFrame.maxX, keepOut.minX)
            case .top: minY = max(visibleFrame.minY, keepOut.maxY)
            case .bottom: maxY = min(visibleFrame.maxY, keepOut.minY)
            }
        }
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}
