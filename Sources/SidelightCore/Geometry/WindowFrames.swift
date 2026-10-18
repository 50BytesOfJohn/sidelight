import CoreGraphics

/// Comparing window frames, wherever Sidelight asked for one and an app decided what it actually became.
///
/// Apps round what they're asked for, and some round to more than a point, so "still where we left it" can't be an
/// equality. The window manager, its size cycle and window avoidance all ask the same question, so they ask it here.
public enum WindowFrames {
    /// Frames this close count as the same: apps round to whole points, and some to more.
    public static let tolerance: CGFloat = 2

    /// Whether a window at `frame` is still where Sidelight left it at `accepted`: every edge within ``tolerance``.
    public static func isUnchanged(_ frame: CGRect, since accepted: CGRect) -> Bool {
        abs(frame.minX - accepted.minX) <= tolerance && abs(frame.minY - accepted.minY) <= tolerance
            && abs(frame.width - accepted.width) <= tolerance && abs(frame.height - accepted.height) <= tolerance
    }
}
