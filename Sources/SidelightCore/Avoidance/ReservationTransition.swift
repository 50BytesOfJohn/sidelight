import CoreGraphics

/// What happens to one window when a display's reservation changes from one strip to another in a single step: a
/// details panel opening in place of the side panel or closing again, the panels being hidden or shown, or a panel
/// moving or resizing.
///
/// - Space the new strip covers pushes windows out of it, as avoidance always does. Space a details panel frees
///   doesn't pull clear windows into it.
/// - A window nobody moved since Sidelight last did goes back where it was before that panel moved it: before the
///   details panel when it closes, before any panel when everything hides. One that was moved or resized since is
///   the user's, and stays.
/// - Except: a window whose near edge touches the closing details panel's inner edge (or sits the usual gap away)
///   follows it back, to the returning side panel's edge, or the screen's edge for a bar, even if it changed. It
///   keeps its far edge and its height. A window Sidelight itself pushed against the details panel only follows
///   when it was snapped to the returning edge before; otherwise it just goes back.
/// - A strip that replaces one on another edge (a bar giving way to a details panel on the left), or the same panel
///   resizing, frees the old strip as it takes the new one: a window the old strip moved and nobody touched since
///   starts from where it was before, so it moves once, straight to its place.
/// - Only the details panel opening gives windows a way back to before it. Moving it during its session (its panel
///   changed sides) keeps the ways back windows already had, and gives none to the others it pushes: they can still
///   follow its edge when it closes.
/// - In *smart* mode a window snapped to the inner edge of the strip it already had clips as the strip grows, as one
///   snapped to the screen's edge does: that edge is where the screen ends for it. And windows side by side with one
///   that's pushed or follows an edge move with it, as a group, so a grid stays a grid (see
///   ``decide(_:from:to:visibleFrame:displayFrame:mode:)``).
///
/// All rects use Accessibility coordinates, as ``AvoidanceGeometry`` does.
public enum ReservationTransition {
    /// Frames this close count as the same (see ``WindowFrames/tolerance``).
    static var tolerance: CGFloat { WindowFrames.tolerance }

    public struct Move: Equatable, Sendable {
        /// Never ``WindowMoveReason/keepClear``: that's everyday avoidance, not a transition.
        public var reason: WindowMoveReason
        public var frame: CGRect
        /// Where to put the window instead if the app refuses ``frame``'s size (it has a minimum).
        public var fallback: CGRect?
        /// The baselines to keep once it has moved, with what the app accepted. Both `nil` forgets the window.
        public var main: CGRect?
        public var details: CGRect?

        public init(
            reason: WindowMoveReason, frame: CGRect, fallback: CGRect? = nil, main: CGRect? = nil,
            details: CGRect? = nil
        ) {
            self.reason = reason
            self.frame = frame
            self.fallback = fallback
            self.main = main
            self.details = details
        }

        /// The baselines to keep, given the frame the app accepted; `nil` forgets the window.
        public func baselines(accepted: CGRect) -> WindowBaselines? {
            main == nil && details == nil ? nil : WindowBaselines(main: main, details: details, accepted: accepted)
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Nothing moves. Remember these baselines, or forget the window with `nil`.
        case leave(WindowBaselines?)
        case move(Move)
    }

    /// What to do with a window at `window`, on a display whose reservation changes from `old` to `new` (`nil`: none).
    ///
    /// *Keep clear* applies to every window: a strip growing into a window pushes it whatever put it there. *Put it
    /// back* applies only to a window avoidance moved itself, which is what `isPlacedOnPurpose` rules out — a
    /// window manager tile isn't avoidance's to undo, so hiding the panels leaves it where it is, and following a
    /// closing details panel's edge isn't its to decide either.
    ///
    /// - Parameters:
    ///   - baselines: What avoidance remembers of the window; `nil` if it never moved it.
    ///   - visibleFrame: The display's visible frame.
    ///   - displayFrame: The display's whole frame. A window that isn't entirely on it never follows an edge.
    ///   - isPlacedOnPurpose: Whether the window is still exactly where a deliberate placement left it.
    public static func decide(
        window: CGRect, baselines: WindowBaselines?, from old: Reservation?, to new: Reservation?,
        visibleFrame: CGRect, displayFrame: CGRect, mode: WindowAvoidanceMode, isPlacedOnPurpose: Bool = false
    ) -> Decision {
        guard mode != .off else { return .leave(nil) }
        let ours = ours(window, baselines: baselines, isPlacedOnPurpose: isPlacedOnPurpose)

        guard let new else {
            // Everything released: back to before any panel moved it.
            guard let ours, let target = ours.earliest, !WindowFrames.isUnchanged(target, since: window) else {
                return .leave(nil)
            }
            return .move(Move(reason: .restore, frame: target))
        }

        if !isPlacedOnPurpose, let old, old.role == .details, new.role == .main,
            let decision = closingDetails(
                window: window, ours: ours, details: old, next: new, visibleFrame: visibleFrame,
                displayFrame: displayFrame, mode: mode)
        {
            return decision
        }

        let (start, kept) = pushStart(window: window, ours: ours, from: old, to: new)

        // The new strip pushes what it covers; what it doesn't cover stays.
        let plan = AvoidanceGeometry.plan(
            window: start, panel: new.frame, visibleFrame: visibleFrame, edge: new.edge,
            mode: pushMode(start, from: old, to: new, mode: mode), clearance: new.clearance)
        let target = plan?.frame ?? start
        guard !WindowFrames.isUnchanged(target, since: window) else { return .leave(ours) }
        return .move(
            Move(
                reason: plan == nil ? .restore : .push, frame: target, fallback: plan?.shiftFallback, main: kept.main,
                details: kept.details))
    }

    /// What avoidance remembers of a window at `window` that's still its to put back: remembered, and nobody has
    /// moved it since. A deliberate placement never is, however much avoidance remembers of where the window used
    /// to be.
    static func ours(_ window: CGRect, baselines: WindowBaselines?, isPlacedOnPurpose: Bool) -> WindowBaselines? {
        isPlacedOnPurpose
            ? nil : baselines.flatMap { WindowFrames.isUnchanged(window, since: $0.accepted) ? $0 : nil }
    }

    /// Where a window at `window` starts from as `new` takes over from `old`, and the baselines it keeps if it moves:
    /// where it would be without the old strip, when the new one frees it, so it moves once.
    static func pushStart(
        window: CGRect, ours: WindowBaselines?, from old: Reservation?, to new: Reservation
    ) -> (start: CGRect, kept: WindowBaselines) {
        var kept = ours ?? WindowBaselines(accepted: window)
        // The details panel moving during its session (its panel changed sides) gives no window a way back to before
        // the session: one without it was opened or moved during the session, and was never anywhere before it.
        let isSameSession = old?.role == .details && new.role == .details
        if let old, let ours, let before = ours[old.role], freesOldStrip(from: old, to: new) {
            if !isSameSession { kept[new.role] = kept[new.role] ?? before }
            return (before, kept)
        }
        if !isSameSession { kept[new.role] = kept[new.role] ?? window }
        return (window, kept)
    }

    /// The mode `new` pushes a window starting at `start` with. *Smart* clips a window snapped to the screen's edge;
    /// one snapped to the inner edge of the strip on that edge is just as snapped, since that edge is where the screen
    /// ends for it. Without this a tile beside the side panel would be shifted whole as the details panel opens, on
    /// top of its neighbour.
    static func pushMode(
        _ start: CGRect, from old: Reservation?, to new: Reservation, mode: WindowAvoidanceMode
    ) -> WindowAvoidanceMode {
        guard mode == .smart, let old, old.edge == new.edge else { return mode }
        let boundary = AvoidanceGeometry.canonical(old.frame, edge: old.edge).maxX
        return contactGap(of: start, edge: new.edge, boundary: boundary, clearance: old.clearance) == nil
            ? mode : .clip
    }

    /// Whether going from `old` to `new` gives back the space `old` took, so windows it moved can come back: a strip on
    /// another edge (a bar replaced by a details panel on the left), or the side panel or bar moving or resizing. A
    /// details panel opening on the side panel's own edge doesn't: space it frees there stays free.
    private static func freesOldStrip(from old: Reservation, to new: Reservation) -> Bool {
        old.edge != new.edge || (old.role == .main && new.role == .main)
    }

    /// The details panel `details` closes and `next` takes its place: snapped windows follow its edge, and windows it
    /// moved go back. `nil` leaves the window to the new strip's usual push.
    private static func closingDetails(
        window: CGRect, ours: WindowBaselines?, details: Reservation, next: Reservation, visibleFrame: CGRect,
        displayFrame: CGRect, mode: WindowAvoidanceMode
    ) -> Decision? {
        let boundary = returningBoundary(details: details, next: next, visibleFrame: visibleFrame)
        // Where it was before the details panel moved it, if nobody touched it since.
        let before = ours?.details
        // A window Sidelight pushed against the details panel touches it because of that push, not because someone
        // snapped it there; it follows the edge back only if it was snapped to the returning edge before.
        let snappedBefore = before.flatMap {
            contactGap(of: $0, edge: details.edge, boundary: boundary, clearance: details.clearance)
        }
        let follow =
            before == nil || snappedBefore != nil
            ? followPlan(
                window: window, details: details, next: next, visibleFrame: visibleFrame, displayFrame: displayFrame,
                mode: mode, gap: snappedBefore)
            : nil

        if let follow {
            // A window someone moved or resized since is theirs: it follows the edge, but isn't put back later.
            let main = ours?.main ?? follow.barBaseline
            guard !WindowFrames.isUnchanged(follow.plan.frame, since: window) else {
                return .leave(main.map { WindowBaselines(main: $0, accepted: window) })
            }
            return .move(
                Move(reason: .follow, frame: follow.plan.frame, fallback: follow.plan.shiftFallback, main: main))
        }

        guard let before else { return nil }
        // Back where it was before the details panel, kept clear of the returning strip.
        let plan = AvoidanceGeometry.plan(
            window: before, panel: next.frame, visibleFrame: visibleFrame, edge: next.edge, mode: mode,
            clearance: next.clearance)
        let target = plan?.frame ?? before
        let main = ours?.main ?? (plan != nil ? before : nil)
        guard !WindowFrames.isUnchanged(target, since: window) else {
            return .leave(main.map { WindowBaselines(main: $0, accepted: window) })
        }
        return .move(Move(reason: .restore, frame: target, fallback: plan?.shiftFallback, main: main))
    }

    /// Where the returning strip's inner edge is, in the canonical space of the details panel's edge: the returning
    /// side panel's edge, or the screen's visible edge when a bar returns.
    static func returningBoundary(details: Reservation, next: Reservation, visibleFrame: CGRect) -> CGFloat {
        let edge = details.edge
        let returnsSidePanel = next.role == .main && next.edge == edge
        return returnsSidePanel
            ? AvoidanceGeometry.canonical(next.frame, edge: edge).maxX
            : AvoidanceGeometry.canonical(visibleFrame, edge: edge).minX
    }

    /// How far `frame`'s near edge is from `boundary` when it's snapped to it: touching it (`0`) or the usual avoidance
    /// gap away, within ``tolerance``. `nil` when it isn't snapped.
    static func contactGap(
        of frame: CGRect, edge: PanelPosition, boundary: CGFloat,
        clearance: CGFloat = Reservation.defaultClearance
    ) -> CGFloat? {
        let near = nearEdge(of: frame, edge: edge)
        if abs(near - boundary) <= tolerance { return 0 }
        if abs(near - (boundary + clearance)) <= tolerance { return clearance }
        return nil
    }

    /// Where a window snapped to the details panel's inner edge goes as the panel closes; `nil` for a window that
    /// isn't snapped to it.
    ///
    /// Snapped means its near edge is on the boundary, or the usual avoidance gap away, within ``tolerance``, and it
    /// overlaps the panel's height. It keeps that gap (or `gap`, the one it had before the details panel pushed it)
    /// against the returning side panel's edge, or the screen's visible edge when a bar returns, and keeps its far
    /// edge and height by resizing; ``AvoidancePlan/shiftFallback`` keeps its size instead, for apps that refuse it.
    /// A returning bar's strip is kept clear too: `barBaseline` is then where the window would be without the bar,
    /// for putting it back when everything hides.
    static func followPlan(
        window: CGRect, details: Reservation, next: Reservation, visibleFrame: CGRect, displayFrame: CGRect,
        mode: WindowAvoidanceMode, gap preservedGap: CGFloat? = nil
    ) -> (plan: AvoidancePlan, barBaseline: CGRect?)? {
        let edge = details.edge
        guard !edge.isBar,
            displayFrame.insetBy(dx: -tolerance, dy: -tolerance).contains(window)
        else { return nil }
        let canonicalWindow = AvoidanceGeometry.canonical(window, edge: edge)
        let panel = AvoidanceGeometry.canonical(details.frame, edge: edge)
        let visible = AvoidanceGeometry.canonical(visibleFrame, edge: edge)
        guard canonicalWindow.minY < panel.maxY, canonicalWindow.maxY > panel.minY,
            let contact = contactGap(of: window, edge: edge, boundary: panel.maxX, clearance: details.clearance)
        else { return nil }

        let boundary = returningBoundary(details: details, next: next, visibleFrame: visibleFrame)
        let near = boundary + (preservedGap ?? contact)
        let shifted = CGRect(
            x: near, y: canonicalWindow.minY, width: max(0, min(canonicalWindow.width, visible.maxX - near)),
            height: canonicalWindow.height)
        let resizedWidth = canonicalWindow.maxX - near

        var plan: AvoidancePlan
        if resizedWidth >= AvoidanceGeometry.minimumClipFraction * canonicalWindow.width {
            let resized = CGRect(
                x: near, y: canonicalWindow.minY, width: resizedWidth, height: canonicalWindow.height)
            plan = AvoidancePlan(
                action: .clip, frame: AvoidanceGeometry.restored(resized, edge: edge),
                shiftFallback: AvoidanceGeometry.restored(shifted, edge: edge))
        } else {
            plan = AvoidancePlan(action: .shift, frame: AvoidanceGeometry.restored(shifted, edge: edge))
        }

        // A returning bar's strip stays clear, as avoidance would keep it.
        guard next.edge.isBar else { return (plan, nil) }
        let unclipped = plan.frame
        plan.frame = clear(plan.frame, of: next, visibleFrame: visibleFrame, mode: mode)
        plan.shiftFallback = plan.shiftFallback.map { clear($0, of: next, visibleFrame: visibleFrame, mode: mode) }
        return (plan, plan.frame == unclipped ? nil : unclipped)
    }

    /// `frame` kept clear of a returning bar, as avoidance would keep it; unchanged for a side panel.
    static func clear(
        _ frame: CGRect, of next: Reservation, visibleFrame: CGRect, mode: WindowAvoidanceMode
    ) -> CGRect {
        guard next.edge.isBar else { return frame }
        return AvoidanceGeometry.plan(
            window: frame, panel: next.frame, visibleFrame: visibleFrame, edge: next.edge, mode: mode,
            clearance: next.clearance)?.frame ?? frame
    }

    /// The near edge of `frame` against a panel on `edge`, in that edge's canonical space.
    static func nearEdge(of frame: CGRect, edge: PanelPosition) -> CGFloat {
        AvoidanceGeometry.canonical(frame, edge: edge).minX
    }
}
