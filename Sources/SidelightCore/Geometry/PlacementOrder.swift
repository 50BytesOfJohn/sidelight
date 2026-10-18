import CoreGraphics

/// One half of a window frame, which is as much as the Accessibility API can set at a time.
public enum FrameWrite: Equatable, Sendable {
    case position(CGPoint)
    case size(CGSize)
}

/// Which half of a window frame to write first, so the window never flashes under a panel on its way.
///
/// Accessibility has no settable combined frame: moving a window to a new frame takes two messages, each its own
/// round trip to the app, and the window is composited in between. So one intermediate frame is on screen for a
/// moment, and which one it is depends on the order:
///
/// | Order | Intermediate frame |
/// | --- | --- |
/// | position, then size | the new origin at the old size |
/// | size, then position | the old origin at the new size |
///
/// Position first is almost always the clear one, because the new origin is already out of the panel's way; size
/// first leaves the window where it was, which for a window under the panel means still under the panel. Size first
/// is right when the window is about to grow past a panel on the far side, so the order is a choice, not a constant.
///
/// Position first also helps an app that refuses the size: for a tile anchored to the leading edge the window is
/// already at the tile's origin by then, so there's nothing left to correct.
public enum PlacementOrder {
    /// A write this far off what the window already has is left out: apps round what they're asked for, and a
    /// message that changes nothing still costs a round trip and can still make an app animate.
    public static let tolerance: CGFloat = 1

    /// The writes that take a window from `current` to `target`, in the order that keeps every frame along the way
    /// clear of the panels in `area`.
    ///
    /// Two writes whenever one order is clear. Three — to a safe origin, the size, then the origin — when neither
    /// is, which happens when the window is inside a keep-out *and* would grow into one. A window too big for the
    /// display gets the order that covers less of a panel; it's going to overhang something either way.
    public static func writes(from current: CGRect, to target: CGRect, in area: WorkArea) -> [FrameWrite] {
        let position = FrameWrite.position(target.origin)
        let size = FrameWrite.size(target.size)
        let moves = !isSame(current.origin, target.origin)
        let resizes = !isSame(current.size, target.size)
        guard moves else { return resizes ? [size] : [] }
        guard resizes else { return [position] }

        let afterMove = CGRect(origin: target.origin, size: current.size)
        if area.isClear(afterMove) { return [position, size] }
        let afterResize = CGRect(origin: current.origin, size: target.size)
        if area.isClear(afterResize) { return [size, position] }

        // Neither two-write order is clear: go by way of an origin that holds both sizes clear of every panel.
        let widest = CGSize(
            width: max(current.width, target.width), height: max(current.height, target.height))
        if let safe = area.safeOrigin(for: widest) { return [.position(safe), size, position] }
        return covered(afterMove, in: area) <= covered(afterResize, in: area)
            ? [position, size] : [size, position]
    }

    /// How much of the panels' strips `frame` covers, for choosing between two orders that both do.
    static func covered(_ frame: CGRect, in area: WorkArea) -> CGFloat {
        area.reservations.reduce(0) { total, reservation in
            let overlap = frame.intersection(reservation.frame)
            return overlap.isNull ? total : total + overlap.width * overlap.height
        }
    }

    private static func isSame(_ point: CGPoint, _ other: CGPoint) -> Bool {
        abs(point.x - other.x) <= tolerance && abs(point.y - other.y) <= tolerance
    }

    private static func isSame(_ size: CGSize, _ other: CGSize) -> Bool {
        abs(size.width - other.width) <= tolerance && abs(size.height - other.height) <= tolerance
    }
}
