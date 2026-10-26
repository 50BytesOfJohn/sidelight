import CoreGraphics

/// Windows side by side move together.
///
/// One window at a time, a layout falls apart as a strip's edge moves: the details panel opening clips the column of
/// a 2×2 grid beside it and leaves the other column where it was, and closing again (or hiding the panels) only
/// brings back what touches its edge. So in *smart* mode, windows that sit side by side along the strip's axis —
/// touching, or the window manager's gap apart, and level with each other — form a group, and the group moves as
/// one: every edge in it is stretched between the strip's new edge and the group's far end, which stays put. Columns
/// stay columns, neighbours stay neighbours; closing the details panel stretches them back, hiding the panels
/// stretches them out to the screen's edge, and showing them squeezes them in again.
///
/// Nothing is remembered for this: the group is found from where the windows are when the edge moves.
extension ReservationTransition {
    /// One window on a display whose reservation is changing.
    public struct Candidate: Equatable, Sendable {
        public var frame: CGRect
        /// What avoidance remembers of the window; `nil` if it never moved it.
        public var baselines: WindowBaselines?
        /// Whether the window is still exactly where a deliberate placement left it.
        public var isPlacedOnPurpose: Bool

        public init(frame: CGRect, baselines: WindowBaselines? = nil, isPlacedOnPurpose: Bool = false) {
            self.frame = frame
            self.baselines = baselines
            self.isPlacedOnPurpose = isPlacedOnPurpose
        }
    }

    /// Windows further apart than this don't count as side by side: the widest gap the window manager leaves between
    /// tiles, and what apps round.
    static var neighbourGap: CGFloat { CGFloat(WindowLayout.spacingRange.upperBound) + tolerance }

    /// What to do with each of `windows`, every window on one display, as its reservation changes from `old` to
    /// `new`: what ``decide(window:baselines:from:to:visibleFrame:displayFrame:mode:isPlacedOnPurpose:screenPadding:)``
    /// says for each, except that in *smart* mode windows side by side with one the strip moves move with it (see
    /// above). In the same order as `windows`.
    public static func decide(
        _ windows: [Candidate], from old: Reservation?, to new: Reservation?, visibleFrame: CGRect,
        displayFrame: CGRect, mode: WindowAvoidanceMode, screenPadding: CGFloat = 0
    ) -> [Decision] {
        var decisions = windows.map {
            decide(
                window: $0.frame, baselines: $0.baselines, from: old, to: new, visibleFrame: visibleFrame,
                displayFrame: displayFrame, mode: mode, isPlacedOnPurpose: $0.isPlacedOnPurpose,
                screenPadding: screenPadding)
        }
        guard mode == .smart else { return decisions }
        if let old, follows(from: old, to: new) {
            followTogether(
                windows, decisions: &decisions, from: old, to: new, visibleFrame: visibleFrame,
                displayFrame: displayFrame, mode: mode, screenPadding: screenPadding)
        } else if let new {
            pushTogether(
                windows, decisions: &decisions, from: old, to: new, visibleFrame: visibleFrame,
                displayFrame: displayFrame)
        }
        return decisions
    }

    /// Whether windows snapped to `old` follow its edge as `new` takes over: it closes, hides or narrows.
    private static func follows(from old: Reservation, to new: Reservation?) -> Bool {
        guard let new else { return true }
        return (old.role == .details && new.role == .main) || isNarrowing(from: old, to: new)
    }

    /// The strip `new` pushes windows: those beside a pushed one are squeezed along with it, between the strip's
    /// inner edge and the group's far end.
    private static func pushTogether(
        _ windows: [Candidate], decisions: inout [Decision], from old: Reservation?, to new: Reservation,
        visibleFrame: CGRect, displayFrame: CGRect
    ) {
        let edge = new.edge
        let starts = windows.map {
            pushStart(
                window: $0.frame,
                ours: ours($0.frame, baselines: $0.baselines, isPlacedOnPurpose: $0.isPlacedOnPurpose),
                from: old, to: new)
        }
        let frames = starts.map { AvoidanceGeometry.canonical($0.start, edge: edge) }
        let isOnDisplay = starts.map { isEntirely($0.start, on: displayFrame) }
        let pushed = decisions.indices.filter { decisions[$0].reason == .push && isOnDisplay[$0] }
        let near = AvoidanceGeometry.canonical(new.frame, edge: edge).maxX + new.clearance

        for group in groups(of: pushed, among: frames, eligible: isOnDisplay) {
            guard let stretch = Stretch(group.map { frames[$0] }, to: near),
                stretch.scale >= AvoidanceGeometry.minimumClipFraction
            else { continue }
            for index in group {
                let (start, kept) = starts[index]
                let target = AvoidanceGeometry.restored(stretch.apply(frames[index]), edge: edge)
                guard !WindowFrames.isUnchanged(target, since: windows[index].frame) else {
                    decisions[index] = .leave(
                        ours(
                            windows[index].frame, baselines: windows[index].baselines,
                            isPlacedOnPurpose: windows[index].isPlacedOnPurpose))
                    continue
                }
                // An app that won't shrink that far is moved out from under the strip whole instead, like any
                // window it pushes.
                let fallback =
                    start.intersects(new.frame)
                    ? AvoidanceGeometry.plan(
                        window: start, panel: new.frame, visibleFrame: visibleFrame, edge: edge, mode: .shift,
                        clearance: new.clearance)?.frame : nil
                decisions[index] = .move(
                    Move(reason: .push, frame: target, fallback: fallback, main: kept.main, details: kept.details))
            }
        }
    }

    /// `strip` gives way to `next`, the side panel or bar coming back as the details panel closes or the same one
    /// narrower, or to nothing as the panels hide: windows beside one that follows its edge are stretched along with
    /// it, between the edge it follows to and the group's far end.
    private static func followTogether(
        _ windows: [Candidate], decisions: inout [Decision], from strip: Reservation, to next: Reservation?,
        visibleFrame: CGRect, displayFrame: CGRect, mode: WindowAvoidanceMode, screenPadding: CGFloat
    ) {
        let edge = strip.edge
        let frames = windows.map { AvoidanceGeometry.canonical($0.frame, edge: edge) }
        let isOnDisplay = windows.map { isEntirely($0.frame, on: displayFrame) }
        let following = decisions.indices.filter { decisions[$0].reason == .follow }
        let stripEdge = AvoidanceGeometry.canonical(strip.frame, edge: edge).maxX

        for group in groups(of: following, among: frames, eligible: isOnDisplay) {
            let start = group.map { frames[$0].minX }.min() ?? stripEdge
            // Back beside the returning strip, with the gap the group had; or out at the screen's edge, at the window
            // manager's padding if it sat the usual gap from the strip.
            let near =
                if let next {
                    returningBoundary(strip: strip, next: next, visibleFrame: visibleFrame)
                        + max(0, start - stripEdge)
                } else {
                    AvoidanceGeometry.canonical(visibleFrame, edge: edge).minX
                        + (start - stripEdge <= tolerance ? 0 : screenPadding)
                }
            guard let stretch = Stretch(group.map { frames[$0] }, to: near) else { continue }
            let ours = group.map { index in
                let window = windows[index]
                return Self.ours(window.frame, baselines: window.baselines, isPlacedOnPurpose: window.isPlacedOnPurpose)
            }
            // A group the details panel pushed and nobody touched since goes back exactly where it was before it:
            // stretching there and back again would be a point out here and there. (Hiding puts back what it can one
            // window at a time, so a group follows only when someone in it isn't avoidance's to put back.)
            let before =
                strip.role == .details && next != nil && ours.allSatisfy { $0?.details != nil }
                ? ours.map { $0?.details } : nil
            for (position, index) in group.enumerated() {
                let window = windows[index]
                let stretched =
                    before?[position]
                    ?? AvoidanceGeometry.restored(stretch.apply(frames[index]), edge: edge)
                let target = next.map { clear(stretched, of: $0, visibleFrame: visibleFrame, mode: mode) } ?? stretched
                // Where hiding everything puts it: back before any panel moved it, or, for a window a returning bar
                // pushes now, where it would be without the bar. Once everything's hidden, nowhere.
                let main = next == nil ? nil : ours[position]?.main ?? (target == stretched ? nil : stretched)
                guard !WindowFrames.isUnchanged(target, since: window.frame) else {
                    decisions[index] = .leave(main.map { WindowBaselines(main: $0, accepted: window.frame) })
                    continue
                }
                decisions[index] = .move(Move(reason: .follow, frame: target, main: main))
            }
        }
    }

    /// The windows side by side with `seeds`, directly or through each other, in groups of more than one: a lone
    /// window is left to its own decision. Only `eligible` windows join.
    ///
    /// Side by side means, in the canonical space of the strip's edge, one's far edge meets the other's near edge,
    /// touching or up to ``neighbourGap`` apart, and they overlap across the axis by more than what apps round.
    static func groups(of seeds: [Int], among frames: [CGRect], eligible: [Bool]) -> [[Int]] {
        var grouped = Set<Int>()
        var groups: [[Int]] = []
        for seed in seeds where !grouped.contains(seed) {
            var group = [seed]
            grouped.insert(seed)
            var next = 0
            while next < group.count {
                let frame = frames[group[next]]
                next += 1
                for index in frames.indices
                where eligible[index] && !grouped.contains(index) && areSideBySide(frame, frames[index]) {
                    group.append(index)
                    grouped.insert(index)
                }
            }
            if group.count > 1 { groups.append(group.sorted()) }
        }
        return groups
    }

    static func areSideBySide(_ a: CGRect, _ b: CGRect) -> Bool {
        let across = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard across > tolerance else { return false }
        let gaps = [b.minX - a.maxX, a.minX - b.maxX]
        return gaps.contains { $0 >= -tolerance && $0 <= neighbourGap }
    }

    private static func isEntirely(_ frame: CGRect, on displayFrame: CGRect) -> Bool {
        displayFrame.insetBy(dx: -tolerance, dy: -tolerance).contains(frame)
    }

    /// Stretches a group along the axis, in canonical space: its near end moves to a new place and its far end stays.
    /// The gaps between neighbours keep their size, so the window manager's gap stays the gap; the windows share out
    /// the rest in proportion, so an edge lined up across rows stays lined up, and neighbours stay neighbours.
    struct Stretch {
        var from: CGFloat
        var to: CGFloat
        var end: CGFloat
        /// The gaps between neighbours, merged where they line up, in order.
        var gaps: [ClosedRange<CGFloat>]

        /// `nil` when the windows would have no room left.
        init?(_ frames: [CGRect], to near: CGFloat) {
            guard let start = frames.map(\.minX).min(), let end = frames.map(\.maxX).max() else { return nil }
            var gaps: [ClosedRange<CGFloat>] = []
            for a in frames {
                for b in frames where b.minX > a.maxX && areSideBySide(a, b) { gaps.append(a.maxX...b.minX) }
            }
            self.gaps = gaps.sorted { $0.lowerBound < $1.lowerBound }.reduce(into: []) { merged, gap in
                if let last = merged.last, gap.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, gap.upperBound)
                } else {
                    merged.append(gap)
                }
            }
            from = start
            to = near
            self.end = end
            guard scale > 0 else { return nil }
        }

        /// How much the windows themselves grow or shrink.
        var scale: CGFloat {
            let fixed = gaps.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
            return (end - to - fixed) / (end - from - fixed)
        }

        func apply(_ frame: CGRect) -> CGRect {
            let minX = position(frame.minX)
            return CGRect(x: minX, y: frame.minY, width: position(frame.maxX) - minX, height: frame.height)
        }

        /// Whole points, so a group stretched out and back again lands where it was.
        private func position(_ x: CGFloat) -> CGFloat {
            // The gaps before `x` keep their size; everything else scales.
            let fixed = gaps.reduce(0) { $0 + max(0, min(x, $1.upperBound) - $1.lowerBound) }
            return (to + fixed + (x - from - fixed) * scale).rounded()
        }
    }
}

extension ReservationTransition.Decision {
    /// Why the window moves; `nil` when it stays.
    var reason: WindowMoveReason? {
        if case .move(let move) = self { move.reason } else { nil }
    }
}
