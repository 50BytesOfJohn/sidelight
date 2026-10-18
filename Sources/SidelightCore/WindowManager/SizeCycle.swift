import CoreGraphics

/// What the window manager last did, for pressing a half again to cycle its size and for sending a tile to another
/// display as the same tile. One value, changed only by presses, so it needs no timer.
///
/// Which window it was is the caller's to tell: it passes whether the window now is the one recorded, so this never
/// sees Accessibility.
public struct SizeCycle: Sendable {
    /// Pressed again within this, a half takes its next size. Long enough for deliberate double and triple presses,
    /// short enough that a press seconds later predictably means a half again.
    public static let window: Duration = .milliseconds(700)

    private struct Last: Sendable {
        /// The action pressed.
        var action: WindowAction
        /// The placement the window took, and at which step: the action pressed, or for a move to another display the
        /// one re-applied there. `nil` when it wasn't a placement.
        var placement: (action: WindowAction, step: Int)?
        var frame: CGRect
        var at: ContinuousClock.Instant
    }

    private var last: Last?

    public init() {}

    /// The step `action` takes now: the next after the last when it's a cycling action pressed again on the same
    /// window, still where it was left, within ``window``; otherwise 0, a half.
    public func step(
        for action: WindowAction, isSameWindow: Bool, frame: CGRect, now: ContinuousClock.Instant,
        cycles: Bool = true
    ) -> Int {
        guard cycles, action.cycles, isSameWindow, let last, last.action == action,
            let placement = last.placement, placement.action == action, now - last.at < Self.window,
            WindowFrames.isUnchanged(frame, since: last.frame)
        else { return 0 }
        return (placement.step + 1) % action.cycleLength
    }

    /// The placement the window still has, whenever it was made: what the last action left it at, if it's the same
    /// window and hasn't moved since.
    public func placement(isSameWindow: Bool, frame: CGRect) -> (action: WindowAction, step: Int)? {
        guard isSameWindow, let last, WindowFrames.isUnchanged(frame, since: last.frame) else { return nil }
        return last.placement
    }

    /// Notes that pressing `action` left the window at `accepted`, the frame the app accepted, in `placement`.
    public mutating func record(
        _ action: WindowAction, placement: (action: WindowAction, step: Int)?, accepted: CGRect,
        now: ContinuousClock.Instant
    ) {
        last = Last(action: action, placement: placement, frame: accepted, at: now)
    }

    public mutating func reset() {
        last = nil
    }
}
