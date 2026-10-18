import AppKit
import Observation
import SidelightCore
import os

/// A window Sidelight has placed, where it was first, and what put it where it is.
struct PlacedWindow {
    let window: ManagedWindow
    var displayID: Display.ID
    /// The display's frame when the window was placed, in Cocoa space. The frames below mean nothing once it changes.
    var displayFrame: CGRect
    /// Where the window was when someone first asked for it to be placed: what ``WindowAction/restore`` puts back.
    /// `nil` while avoidance is the only thing that has moved it — a window avoidance pushed is put back by hiding
    /// the panels, not by a window manager shortcut.
    var baseline: CGRect?
    /// What window avoidance may put back when a strip is released, and where it was before each panel moved it.
    /// `nil` once a placement was deliberate: a tile isn't avoidance's to undo.
    var avoidance: WindowBaselines?
    var lastRequested: CGRect
    /// What the app actually took, which an app with a minimum, maximum or quantised size makes differ.
    var lastAccepted: CGRect
    var intent: PlacementIntent
}

/// The only thing that moves a window: the window manager's tiles, window avoidance and Sidelight's own windows all
/// place through it, and it keeps one record per window.
///
/// **Why one writer.** Accessibility has no settable combined frame, so a placement is two messages with the window
/// composited in between, and until now the order was hardcoded for avoidance's benefit — size first, which leaves
/// the window at its old origin at its new size. For a window that was under the panel to begin with, that
/// intermediate frame is a window under the panel, which is why one keypress looked like two moves.
/// ``PlacementOrder`` now picks the order so no frame along the way covers a panel, the app's enhanced user
/// interface is off for the *whole* placement rather than per write, and corrections happen inside the same scope,
/// so a window settles once.
///
/// **Why one registry.** Both features used to remember "a window we moved, and where it was", and the window
/// manager had to reach into avoidance and delete a row after every tile so avoidance wouldn't put the tile back.
/// Instead a placement says what kind of placement it was: *keep clear* applies to every window, whatever put it
/// there, and *put it back* only ever applies to a window avoidance moved itself (see ``PlacementIntent``).
///
/// Only ever in memory, and only for this run.
@Observable
final class WindowPlacer {
    /// How many windows it remembers, which is how many ``WindowAction/restore`` can put back. The least recently
    /// placed goes first.
    static let limit = 64
    /// A correction this small isn't worth a message: apps round what they're asked for.
    static let correctionTolerance: CGFloat = 1

    @ObservationIgnored private var records: [PlacedWindow] = []

    // MARK: Placing

    /// Puts `window` at `requested`, and returns the frame the app accepted; `nil` once the window is gone.
    ///
    /// Everything that can make an app end up somewhere else happens inside one placement, so the window settles
    /// once and an app that animates frame changes animates one move:
    ///
    ///  1. the writes ``PlacementOrder`` chose, in its order;
    ///  2. `fallback`, for an app that refused to shrink along its axis because it has a minimum size;
    ///  3. `correcting`, where the caller wants the window given the size the app settled on — the window manager
    ///     anchors a window to the edges of the tile it asked for;
    ///  4. `clearOf`, so an app that kept a size too big for the room beside a panel is still out from under it;
    ///  5. the retries, last, for an app that clamped a write while the other half was still the old one.
    ///
    /// - Parameters:
    ///   - intent: Why it's being placed, which decides what may move it next.
    ///   - display: The display it's being placed on, whose work area the intermediate frames are checked against.
    @discardableResult
    func place(
        _ window: ManagedWindow, at requested: CGRect, fallback: (frame: CGRect, axis: PanelPosition)? = nil,
        intent: PlacementIntent, on display: DisplayArea?, clearOf reservation: Reservation? = nil,
        correcting: ((CGRect) -> CGRect)? = nil, reason: String
    ) -> CGRect? {
        guard let current = window.frame else { return nil }
        // Without a display there's nothing to stay clear of, so any order will do.
        let area = display?.workArea ?? WorkArea.unreserved(.infinite)

        let accepted = withEnhancedUserInterfaceOff(of: window) { () -> CGRect? in
            var target = requested
            guard var accepted = write(window, to: target, from: current, in: area) else { return nil }
            if let fallback,
                AvoidanceGeometry.clipWasRefused(requested: target, actual: accepted, edge: fallback.axis)
            {
                target = fallback.frame
                accepted = write(window, to: target, from: accepted, in: area) ?? accepted
            }
            if let correcting {
                // What the caller wants given the size the app settled on, which becomes what the retries aim at:
                // asking again for a size the app has already refused would only undo the correction.
                target = correcting(accepted)
                if !WindowFrames.isUnchanged(target, since: accepted) {
                    accepted = write(window, to: target, from: accepted, in: area) ?? accepted
                }
            }
            if let reservation,
                let clear = AvoidanceGeometry.clearing(
                    accepted, of: reservation.frame, edge: reservation.edge, clearance: reservation.clearance)
            {
                Log.placement.debug(
                    """
                    \(reason, privacy: .public): the app kept \(NSStringFromRect(accepted), privacy: .public) over \
                    the panel; moving it to \(NSStringFromRect(clear), privacy: .public)
                    """
                )
                target = clear
                accepted = write(window, to: target, from: accepted, in: area) ?? accepted
            }
            return retrying(window, towards: target, accepted: accepted)
        }

        guard let accepted else { return nil }
        remember(window, before: current, requested: requested, accepted: accepted, intent: intent, on: display)
        return accepted
    }

    /// Writes `target`, in the order that keeps every frame along the way clear of the panels, and reads back what
    /// the app took. One write for Sidelight's own windows, which take a whole frame at once.
    private func write(
        _ window: ManagedWindow, to target: CGRect, from current: CGRect, in area: WorkArea
    )
        -> CGRect?
    {
        if window.takesWholeFrames { return window.setWholeFrame(target) }
        for frameWrite in PlacementOrder.writes(from: current, to: target, in: area) { window.write(frameWrite) }
        return window.frame
    }

    /// An app that clamped one half of the frame while the other was still the old one gets that half again: a
    /// window asked to move and shrink can be held on screen at its old size, and one asked to grow in place can be
    /// held at its old origin. Last of all, so the window settles once.
    private func retrying(_ window: ManagedWindow, towards target: CGRect, accepted: CGRect) -> CGRect {
        guard !window.takesWholeFrames else { return accepted }
        var actual = accepted
        let tolerance = Self.correctionTolerance
        if abs(actual.width - target.width) > tolerance || abs(actual.height - target.height) > tolerance {
            window.write(.size(target.size))
            actual = window.frame ?? actual
        }
        if abs(actual.minX - target.minX) > tolerance || abs(actual.minY - target.minY) > tolerance {
            window.write(.position(target.origin))
            actual = window.frame ?? actual
        }
        return actual
    }

    /// Runs `placement` with the app's enhanced user interface off, and puts it back after. Scoped to the whole
    /// placement, so an app that animates frame changes never animates a correction as a move of its own.
    private func withEnhancedUserInterfaceOff<Value>(of window: ManagedWindow, _ placement: () -> Value) -> Value {
        guard let pid = window.processIdentifier else { return placement() }
        let application = AccessibilityElement.application(pid)
        let wasOn = application.hasEnhancedUserInterface
        if wasOn { application.setEnhancedUserInterface(false) }
        defer { if wasOn { application.setEnhancedUserInterface(true) } }
        return placement()
    }

    // MARK: The registry

    /// Notes where `window` was, where it went, and what put it there.
    ///
    /// A window still where Sidelight last left it keeps the baseline it had, so a run of tiles still puts back the
    /// frame from before the first of them; one moved since starts over from where it was. Only a deliberate
    /// placement sets a baseline at all, and it drops what avoidance could put back: the window is where someone
    /// asked for it, not where avoidance left it.
    private func remember(
        _ window: ManagedWindow, before: CGRect, requested: CGRect, accepted: CGRect, intent: PlacementIntent,
        on display: DisplayArea?
    ) {
        prune()
        let previous = records.firstIndex { $0.window.isSame(as: window) }.map { records.remove(at: $0) }
        let onSameDisplay =
            previous.map { entry in
                display.map { $0.id == entry.displayID && $0.cocoaFrame == entry.displayFrame } ?? true
            } ?? false
        let isUntouched =
            onSameDisplay && previous.map { WindowFrames.isUnchanged(before, since: $0.lastAccepted) } ?? false
        records.append(
            PlacedWindow(
                window: window,
                displayID: display?.id ?? previous?.displayID ?? "",
                displayFrame: display?.cocoaFrame ?? previous?.displayFrame ?? .null,
                baseline: baseline(before: before, previous: previous, isUntouched: isUntouched, intent: intent),
                avoidance: intent.isDeliberate ? nil : (isUntouched ? previous?.avoidance : nil),
                lastRequested: requested,
                lastAccepted: accepted,
                intent: intent))
        if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
    }

    /// Where the window was when it was first placed on purpose, which is what ``WindowAction/restore`` puts back;
    /// `nil` when nothing ever placed it on purpose.
    func baseline(of window: ManagedWindow) -> CGRect? {
        records.last { $0.window.isSame(as: window) }?.baseline
    }

    /// What ``WindowAction/restore`` puts back after this placement: where the window was when it was first placed
    /// on purpose. A run of tiles keeps the frame from before the first of them; a window moved since starts over.
    private func baseline(
        before: CGRect, previous: PlacedWindow?, isUntouched: Bool, intent: PlacementIntent
    ) -> CGRect? {
        let kept = isUntouched ? previous?.baseline : nil
        return intent.isDeliberate ? (kept ?? before) : kept
    }

    /// Whether `window`, now at `frame`, is still exactly where a deliberate placement left it. The one predicate
    /// that used to be a call from the window manager into avoidance, deleting a row.
    func isPlacedOnPurpose(_ window: ManagedWindow, at frame: CGRect) -> Bool {
        guard let record = records.last(where: { $0.window.isSame(as: window) }), record.intent.isDeliberate else {
            return false
        }
        return WindowFrames.isUnchanged(frame, since: record.lastAccepted)
    }

    /// Forgets `window` entirely: ``WindowAction/restore`` has put it back where it started, so there's nothing left
    /// to put back.
    func forget(_ window: ManagedWindow) {
        records.removeAll { $0.window.isSame(as: window) }
    }

    /// Forgets an app that quit. Its process identifier may be handed to another app at any time.
    func forget(pid: pid_t) {
        records.removeAll { $0.window.processIdentifier == pid }
    }

    // MARK: What avoidance may put back

    /// What avoidance remembers of `window` on `display`: `nil` when it never moved it, when someone has moved it
    /// since, when the record belongs to another process or display, or when the window sits where someone asked for
    /// it to be.
    func avoidanceBaselines(of window: ManagedWindow, on display: DisplayArea) -> WindowBaselines? {
        guard let record = records.last(where: { $0.window.isSame(as: window) }),
            record.displayID == display.id, record.displayFrame == display.cocoaFrame
        else { return nil }
        return record.avoidance
    }

    /// Notes what avoidance may put back for `window`, now at `frame`, or that there's nothing: only avoidance knows
    /// which of its layers a move leaves a way back through (see ``WindowBaselines``).
    ///
    /// Records the window if nothing has placed it yet, because a window avoidance decided to *leave* where it is
    /// can still gain a way back: a returning bar keeps its strip clear, and where the window would be without that
    /// strip is where hiding the panels puts it.
    func setAvoidanceBaselines(
        _ baselines: WindowBaselines?, of window: ManagedWindow, at frame: CGRect, on display: DisplayArea?
    ) {
        if let index = records.lastIndex(where: { $0.window.isSame(as: window) }) {
            records[index].avoidance = baselines
            return
        }
        guard let baselines else { return }
        records.append(
            PlacedWindow(
                window: window, displayID: display?.id ?? "", displayFrame: display?.cocoaFrame ?? .null,
                baseline: nil, avoidance: baselines, lastRequested: frame, lastAccepted: frame,
                intent: .avoidance(.keepClear)))
        if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
    }

    /// Every window avoidance has something to put back for.
    var withAvoidanceBaselines: [PlacedWindow] {
        records.filter { $0.avoidance != nil }
    }

    /// Drops what avoidance may put back for every window: access was revoked, avoidance was switched off, or
    /// everything has been put back already. The baselines ``WindowAction/restore`` uses stay.
    func forgetAvoidance() {
        for index in records.indices { records[index].avoidance = nil }
    }

    /// Drops what avoidance may put back for the windows on `displays` that `keep` doesn't name: a window remembered
    /// there and not found when the strips changed (closed, minimized, full screen, or its app can't be asked) has
    /// nowhere to go back to.
    func forgetAvoidance(onDisplays displays: Set<Display.ID>, except keep: (ManagedWindow) -> Bool) {
        for index in records.indices
        where displays.contains(records[index].displayID) && !keep(records[index].window) {
            records[index].avoidance = nil
        }
    }

    /// Drops what avoidance may put back on displays that are gone or have changed shape: a frame remembered there
    /// doesn't mean anything any more.
    func forgetAvoidanceOnStaleDisplays(among displays: [Display]) {
        for index in records.indices
        where !displays.contains(where: {
            $0.id == records[index].displayID && $0.frame == records[index].displayFrame
        }) {
            records[index].avoidance = nil
        }
    }

    /// Forgets where the windows the manager placed came from, which is what switching it off means. What avoidance
    /// may put back stays; a record with neither left goes.
    func forgetDeliberatePlacements() {
        for index in records.indices { records[index].baseline = nil }
        records.removeAll { $0.avoidance == nil }
    }

    /// Drops records for windows that no longer exist: one of Sidelight's own windows, once it's closed.
    private func prune() {
        records.removeAll { !$0.window.exists }
    }
}
