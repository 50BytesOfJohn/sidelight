import CoreGraphics

/// Where Sidelight puts its own windows (Widgets, Settings, the builder) so its panel never covers them. Window
/// avoidance moves other apps' windows through Accessibility; Sidelight's own it simply places.
///
/// Works in any coordinate space, as long as every rect is in the same one: it reasons about which side of the
/// panel has room, not about which edge is up.
public enum OwnWindowPlacement {
    /// The part of `visibleFrame` a window can use beside `panels`: the largest stretch of it left on any side of
    /// each panel, less the gap window avoidance keeps. The whole visible frame when no panel is in it.
    public static func freeFrame(in visibleFrame: CGRect, beside panels: [CGRect]) -> CGRect {
        panels.reduce(visibleFrame) { free, panel in
            let panel = panel.intersection(free)
            guard !panel.isNull, !panel.isEmpty else { return free }
            let gap = AvoidanceGeometry.gap
            let sides = [
                CGRect(x: free.minX, y: free.minY, width: panel.minX - gap - free.minX, height: free.height),
                CGRect(x: panel.maxX + gap, y: free.minY, width: free.maxX - panel.maxX - gap, height: free.height),
                CGRect(x: free.minX, y: free.minY, width: free.width, height: panel.minY - gap - free.minY),
                CGRect(x: free.minX, y: panel.maxY + gap, width: free.width, height: free.maxY - panel.maxY - gap),
            ]
            return sides.max { $0.width * $0.height < $1.width * $1.height } ?? free
        }
    }

    /// `window` moved and, only if it must, shrunk to fit `free`, never below `minimumSize`. A window that already
    /// fits stays where it is. One that can't shrink enough starts right beside the panel and reaches away from it,
    /// overlapping it only as much as the screen forces.
    public static func fit(_ window: CGRect, minimumSize: CGSize, in free: CGRect, visibleFrame: CGRect) -> CGRect {
        guard !free.contains(window) else { return window }
        let width = max(min(window.width, free.width), min(minimumSize.width, visibleFrame.width))
        let height = max(min(window.height, free.height), min(minimumSize.height, visibleFrame.height))
        let x = place(
            window.minX, length: width, in: free.minX...free.maxX, within: visibleFrame.minX...visibleFrame.maxX,
            awayFromLow: free.minX > visibleFrame.minX)
        let y = place(
            window.minY, length: height, in: free.minY...free.maxY, within: visibleFrame.minY...visibleFrame.maxY,
            awayFromLow: free.minY > visibleFrame.minY)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Where a span of `length` starts on one axis: as near `start` as `free` allows, or, if it doesn't fit, at the
    /// end of `free` next to the panel, reaching away from it, kept on screen.
    private static func place(
        _ start: CGFloat, length: CGFloat, in free: ClosedRange<CGFloat>, within visible: ClosedRange<CGFloat>,
        awayFromLow: Bool
    ) -> CGFloat {
        let origin =
            if length <= free.upperBound - free.lowerBound {
                min(max(start, free.lowerBound), free.upperBound - length)
            } else {
                // The panel is on the low side when the free part starts past the screen's start.
                awayFromLow ? free.lowerBound : free.upperBound - length
            }
        return min(max(origin, visible.lowerBound), visible.upperBound - length)
    }
}
