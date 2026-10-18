import CoreGraphics

/// Pure geometry for the window manager, independent of the Accessibility API.
///
/// Every rect is in Accessibility space, as in ``AvoidanceGeometry``: origin at the top-left of the primary screen,
/// y growing downwards.
public enum WindowLayout {
    /// What the gap and padding settings offer, in points.
    public static let spacingRange = 0...32

    /// Where tiles go on one display: its visible frame (without the menu bar and Dock), less the strip a panel
    /// reserves on it and ``AvoidanceGeometry/gap`` beside that, less `padding` along its other edges.
    ///
    /// Beside a panel the space is always the avoidance gap, whatever the padding, so a tile sits exactly where window
    /// avoidance would leave a window.
    public static func workArea(visibleFrame: CGRect, reservations: [Reservation], padding: CGFloat) -> CGRect {
        var minX = visibleFrame.minX + padding
        var minY = visibleFrame.minY + padding
        var maxX = visibleFrame.maxX - padding
        var maxY = visibleFrame.maxY - padding
        let gap = AvoidanceGeometry.gap
        for reservation in reservations {
            let panel = reservation.frame
            switch reservation.edge {
            case .left: minX = max(visibleFrame.minX, panel.maxX + gap)
            case .right: maxX = min(visibleFrame.maxX, panel.minX - gap)
            case .top: minY = max(visibleFrame.minY, panel.maxY + gap)
            case .bottom: maxY = min(visibleFrame.maxY, panel.minY - gap)
            }
        }
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// The frame `action` gives a window at `step` of its cycle in `area`; `nil` for an action that isn't a tile.
    ///
    /// Each boundary is rounded once and both neighbours derive from it, so complementary tiles never overlap or leave
    /// a seam; inner edges then step back half the `gap` each, so neighbours are exactly `gap` apart.
    public static func frame(
        for action: WindowAction, step: Int = 0, in area: CGRect, gap: CGFloat, isPortrait: Bool = false
    ) -> CGRect? {
        guard let unit = action.unitRect(step: step, isPortrait: isPortrait) else { return nil }
        return frame(of: unit, in: area, gap: gap)
    }

    static func frame(of unit: UnitRect, in area: CGRect, gap: CGFloat) -> CGRect {
        let leading = (gap / 2).rounded(.down)
        let trailing = gap - leading
        func boundary(_ fraction: Double, from start: CGFloat, length: CGFloat) -> CGFloat {
            if fraction <= 0 { return start }
            if fraction >= 1 { return start + length }
            return (start + CGFloat(fraction) * length).rounded(.down)
        }
        // An inner start edge sits after the gap; an inner end edge before it.
        func start(_ fraction: Double, _ origin: CGFloat, _ length: CGFloat) -> CGFloat {
            boundary(fraction, from: origin, length: length) + (fraction > 0 ? trailing : 0)
        }
        func end(_ fraction: Double, _ origin: CGFloat, _ length: CGFloat) -> CGFloat {
            boundary(fraction, from: origin, length: length) - (fraction < 1 ? leading : 0)
        }
        let minX = start(unit.minX, area.minX, area.width)
        let maxX = end(unit.maxX, area.minX, area.width)
        let minY = start(unit.minY, area.minY, area.height)
        let maxY = end(unit.maxY, area.minY, area.height)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// A window of `size` centred in `area`, no bigger than it.
    public static func centered(_ size: CGSize, in area: CGRect) -> CGRect {
        let width = min(size.width, area.width)
        let height = min(size.height, area.height)
        return CGRect(
            x: (area.midX - width / 2).rounded(.down), y: (area.midY - height / 2).rounded(.down), width: width,
            height: height)
    }

    /// Where a window the app sized `accepted` goes when it refused `tile`'s size (a minimum or maximum size): against
    /// the edges of the work area the tile touches (left for a left half, top and right for the top-right corner),
    /// centred in the tile along an axis where it touches both or neither, then moved into `area` where it fits.
    /// `isPortrait` is the display's, as the tile was laid out for: a third's edges depend on it.
    public static func anchored(
        _ accepted: CGSize, for action: WindowAction, tile: CGRect, in area: CGRect, isPortrait: Bool = false
    ) -> CGRect {
        let unit =
            action.unitRect(isPortrait: isPortrait) ?? UnitRect(minX: 0.5, minY: 0.5, maxX: 0.5, maxY: 0.5)
        func origin(start: Double, end: Double, tileMin: CGFloat, tileLength: CGFloat, length: CGFloat) -> CGFloat {
            switch (start <= 0, end >= 1) {
            case (true, false): tileMin
            case (false, true): tileMin + tileLength - length
            default: (tileMin + (tileLength - length) / 2).rounded(.down)
            }
        }
        let x = origin(
            start: unit.minX, end: unit.maxX, tileMin: tile.minX, tileLength: tile.width, length: accepted.width)
        let y = origin(
            start: unit.minY, end: unit.maxY, tileMin: tile.minY, tileLength: tile.height, length: accepted.height)
        return clamped(CGRect(origin: CGPoint(x: x, y: y), size: accepted), to: area)
    }

    /// `size` within a window's minimum and maximum sizes, as an app would size it when asked for `size`.
    public static func clampedSize(_ size: CGSize, minimum: CGSize, maximum: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minimum.width), max(minimum.width, maximum.width)),
            height: min(max(size.height, minimum.height), max(minimum.height, maximum.height)))
    }

    /// `frame` moved (never resized) into `area` along each axis where it fits; against its leading edge where not.
    public static func clamped(_ frame: CGRect, to area: CGRect) -> CGRect {
        func origin(_ value: CGFloat, length: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
            length >= upper - lower ? lower : value.clamped(to: lower...(upper - length))
        }
        return CGRect(
            x: origin(frame.minX, length: frame.width, min: area.minX, max: area.maxX),
            y: origin(frame.minY, length: frame.height, min: area.minY, max: area.maxY),
            width: frame.width, height: frame.height)
    }

    /// `frame` in the work area `source` mapped to the work area `target`: its origin and size keep their proportions,
    /// then it's sized and moved to fit.
    public static func transfer(_ frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return centered(frame.size, in: target) }
        let scaleX = target.width / source.width
        let scaleY = target.height / source.height
        let mapped = CGRect(
            x: (target.minX + (frame.minX - source.minX) * scaleX).rounded(),
            y: (target.minY + (frame.minY - source.minY) * scaleY).rounded(),
            width: min(target.width, (frame.width * scaleX).rounded()),
            height: min(target.height, (frame.height * scaleY).rounded()))
        return clamped(mapped, to: target)
    }

    /// The display a window at `frame` is on: the one holding most of it, then the one holding its centre, then the
    /// first. `nil` without displays.
    public static func sourceDisplay(of frame: CGRect, among displays: [CGRect]) -> Int? {
        guard !displays.isEmpty else { return nil }
        let areas = displays.map { display -> CGFloat in
            let overlap = display.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        let largest = areas.max() ?? 0
        let tied = areas.indices.filter { areas[$0] == largest }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return tied.first { displays[$0].contains(center) } ?? tied.first
    }

    /// The displays' indices left to right, then top to bottom.
    public static func displayOrder(_ displays: [CGRect]) -> [Int] {
        displays.indices.sorted { a, b in
            displays[a].minX != displays[b].minX
                ? displays[a].minX < displays[b].minX : displays[a].minY < displays[b].minY
        }
    }

    /// The display after (or before) `index` in ``displayOrder(_:)``, wrapping around; `nil` with only one.
    public static func neighbor(of index: Int, among displays: [CGRect], forward: Bool) -> Int? {
        let order = displayOrder(displays)
        guard order.count > 1, let position = order.firstIndex(of: index) else { return nil }
        let next = (position + (forward ? 1 : order.count - 1)) % order.count
        return order[next]
    }
}
