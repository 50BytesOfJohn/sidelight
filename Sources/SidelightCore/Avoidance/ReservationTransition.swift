import CoreGraphics

/// What reserves a display's edge: the panel itself, or the details panel standing in for it.
public enum ReservationRole: String, Sendable {
    case main
    case details
}

/// The strip a display keeps clear, in Accessibility coordinates (see ``AvoidanceGeometry``).
public struct Reservation: Equatable, Sendable {
    public var frame: CGRect
    public var edge: PanelPosition
    public var role: ReservationRole

    public init(frame: CGRect, edge: PanelPosition, role: ReservationRole) {
        self.frame = frame
        self.edge = edge
        self.role = role
    }
}

/// Where a window was before Sidelight moved it, for each panel that did, and where Sidelight left it. A layer per
/// panel, so closing the details panel puts a window back where the side panel had it, and hiding everything puts
/// it back where it was before either.
public struct WindowBaselines: Equatable, Sendable {
    /// Before the side panel or bar first moved it.
    public var main: CGRect?
    /// Before the details panel first moved it.
    public var details: CGRect?
    /// The frame the app ended up with the last time Sidelight moved it, which may not be what was asked for.
    public var accepted: CGRect

    public init(main: CGRect? = nil, details: CGRect? = nil, accepted: CGRect) {
        self.main = main
        self.details = details
        self.accepted = accepted
    }

    /// Where it was before any panel moved it.
    public var earliest: CGRect? { main ?? details }

    public subscript(role: ReservationRole) -> CGRect? {
        get {
            switch role {
            case .main: main
            case .details: details
            }
        }
        set {
            switch role {
            case .main: main = newValue
            case .details: details = newValue
            }
        }
    }
}

/// What happens to one window when a display's reservation changes from one strip to another in a single step: a
/// details panel opening in place of the side panel or closing again, or the panels being hidden or shown.
///
/// - Space the new strip covers pushes windows out of it, as avoidance always does. Space it frees doesn't pull clear
///   windows into it.
/// - A window nobody moved since Sidelight last did goes back where it was before that panel moved it: before the
///   details panel when it closes, before any panel when everything hides. One that was moved or resized since is
///   the user's, and stays.
/// - Except: a window whose near edge touches the closing details panel's inner edge (or sits the usual gap away)
///   follows it back, to the returning side panel's edge, or the screen's edge for a bar, even if it changed.
///
/// All rects use Accessibility coordinates, as ``AvoidanceGeometry`` does.
public enum ReservationTransition {
    /// Frames this close count as the same: apps round to whole points, and some to more.
    public static let tolerance: CGFloat = 2

    public struct Move: Equatable, Sendable {
        public enum Reason: String, Sendable {
            /// Out of a newly reserved strip.
            case push
            /// Back where it was before a panel moved it.
            case restore
            /// Following the edge it was snapped to.
            case follow
        }

        public var reason: Reason
        public var frame: CGRect
        /// Where to put the window instead if the app refuses ``frame``'s size (it has a minimum).
        public var fallback: CGRect?
        /// The baselines to keep once it has moved, with what the app accepted. Both `nil` forgets the window.
        public var main: CGRect?
        public var details: CGRect?

        public init(
            reason: Reason, frame: CGRect, fallback: CGRect? = nil, main: CGRect? = nil, details: CGRect? = nil
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

    /// Whether a window at `frame` is still where Sidelight left it at `accepted`: every edge within ``tolerance``.
    public static func isUnchanged(_ frame: CGRect, since accepted: CGRect) -> Bool {
        abs(frame.minX - accepted.minX) <= tolerance && abs(frame.minY - accepted.minY) <= tolerance
            && abs(frame.width - accepted.width) <= tolerance && abs(frame.height - accepted.height) <= tolerance
    }

    /// What to do with a window at `window`, on a display whose reservation changes from `old` to `new` (`nil`: none).
    ///
    /// - Parameters:
    ///   - baselines: What Sidelight remembers of the window; `nil` if it never moved it.
    ///   - visibleFrame: The display's visible frame.
    ///   - displayFrame: The display's whole frame. A window that isn't entirely on it never follows an edge.
    public static func decide(
        window: CGRect, baselines: WindowBaselines?, from old: Reservation?, to new: Reservation?,
        visibleFrame: CGRect, displayFrame: CGRect, mode: WindowAvoidanceMode
    ) -> Decision {
        guard mode != .off else { return .leave(nil) }
        // Remembered, and nobody has moved it since: still Sidelight's to put back.
        let ours = baselines.flatMap { isUnchanged(window, since: $0.accepted) ? $0 : nil }

        guard let new else {
            // Everything released: back to before any panel moved it.
            guard let ours, let target = ours.earliest, !isUnchanged(target, since: window) else {
                return .leave(nil)
            }
            return .move(Move(reason: .restore, frame: target))
        }

        if let old, old.role == .details, new.role == .main {
            if let decision = closingDetails(
                window: window, ours: ours, details: old, next: new, visibleFrame: visibleFrame,
                displayFrame: displayFrame, mode: mode)
            {
                return decision
            }
        }

        // The new strip pushes what it covers; what it doesn't cover stays.
        guard
            let plan = AvoidanceGeometry.plan(
                window: window, panel: new.frame, visibleFrame: visibleFrame, edge: new.edge, mode: mode)
        else { return .leave(ours) }
        var kept = ours ?? WindowBaselines(accepted: window)
        kept[new.role] = kept[new.role] ?? window
        return .move(
            Move(
                reason: .push, frame: plan.frame, fallback: plan.shiftFallback, main: kept.main,
                details: kept.details))
    }

    /// The details panel `details` closes and `next` takes its place: snapped windows follow its edge, and windows it
    /// moved go back. `nil` leaves the window to the new strip's usual push.
    private static func closingDetails(
        window: CGRect, ours: WindowBaselines?, details: Reservation, next: Reservation, visibleFrame: CGRect,
        displayFrame: CGRect, mode: WindowAvoidanceMode
    ) -> Decision? {
        // Where it was before the details panel, kept clear of the returning strip.
        let restore: (plan: AvoidancePlan?, before: CGRect)? = ours?.details.map { before in
            let plan = AvoidanceGeometry.plan(
                window: before, panel: next.frame, visibleFrame: visibleFrame, edge: next.edge, mode: mode)
            return (plan, before)
        }
        let follow = followPlan(
            window: window, details: details, next: next, visibleFrame: visibleFrame, displayFrame: displayFrame,
            mode: mode)

        if let restore {
            let target = restore.plan?.frame ?? restore.before
            // Putting it back keeps it touching the returning edge, or it never touched: the exact old frame wins.
            let keepsContact =
                follow.map { abs(nearEdge(of: target, edge: details.edge) - $0.near) <= tolerance } ?? true
            if keepsContact {
                let main = ours?.main ?? (restore.plan != nil ? restore.before : nil)
                if isUnchanged(target, since: window) {
                    return .leave(main.map { WindowBaselines(main: $0, accepted: window) })
                }
                return .move(
                    Move(reason: .restore, frame: target, fallback: restore.plan?.shiftFallback, main: main))
            }
        }

        guard let follow else { return nil }
        // A window someone moved or resized since is theirs: it follows the edge, but isn't put back later.
        return .move(
            Move(reason: .follow, frame: follow.plan.frame, fallback: follow.plan.shiftFallback, main: ours?.main))
    }

    /// Where a window snapped to the details panel's inner edge goes as the panel closes, and the position of its
    /// near edge then (in the canonical space of the details panel's edge); `nil` for a window that isn't snapped to
    /// it.
    ///
    /// Snapped means its near edge is on the boundary, or the usual avoidance gap away, within ``tolerance``, and it
    /// overlaps the panel's height. It keeps that gap against the returning side panel's edge, or the screen's
    /// visible edge when a bar returns, and keeps its far edge by resizing; ``AvoidancePlan/shiftFallback`` keeps
    /// its size instead, for apps that refuse it. A returning bar's strip is kept clear too.
    static func followPlan(
        window: CGRect, details: Reservation, next: Reservation, visibleFrame: CGRect, displayFrame: CGRect,
        mode: WindowAvoidanceMode
    ) -> (plan: AvoidancePlan, near: CGFloat)? {
        let edge = details.edge
        guard !edge.isBar,
            displayFrame.insetBy(dx: -tolerance, dy: -tolerance).contains(window)
        else { return nil }
        let canonicalWindow = AvoidanceGeometry.canonical(window, edge: edge)
        let panel = AvoidanceGeometry.canonical(details.frame, edge: edge)
        let visible = AvoidanceGeometry.canonical(visibleFrame, edge: edge)
        guard canonicalWindow.minY < panel.maxY, canonicalWindow.maxY > panel.minY else { return nil }

        let gap: CGFloat
        if abs(canonicalWindow.minX - panel.maxX) <= tolerance {
            gap = 0
        } else if abs(canonicalWindow.minX - (panel.maxX + AvoidanceGeometry.gap)) <= tolerance {
            gap = AvoidanceGeometry.gap
        } else {
            return nil
        }

        let returnsSidePanel = next.role == .main && next.edge == edge
        let boundary = returnsSidePanel ? AvoidanceGeometry.canonical(next.frame, edge: edge).maxX : visible.minX
        let near = boundary + gap
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
        if next.edge.isBar {
            func clear(_ frame: CGRect) -> CGRect {
                AvoidanceGeometry.plan(
                    window: frame, panel: next.frame, visibleFrame: visibleFrame, edge: next.edge, mode: mode)?.frame
                    ?? frame
            }
            plan.frame = clear(plan.frame)
            plan.shiftFallback = plan.shiftFallback.map(clear)
        }
        return (plan, near)
    }

    /// The near edge of `frame` against a panel on `edge`, in that edge's canonical space.
    static func nearEdge(of frame: CGRect, edge: PanelPosition) -> CGFloat {
        AvoidanceGeometry.canonical(frame, edge: edge).minX
    }
}
