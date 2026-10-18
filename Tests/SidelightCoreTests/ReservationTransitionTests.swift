import CoreGraphics
import Testing

@testable import SidelightCore

struct DetailsGeometryTests {
    @Test(arguments: [PanelPosition.left, .right, .top, .bottom])
    func `details stay on origin display with fixed width and replace bar on left`(position: PanelPosition) {
        let visible = CGRect(x: -1440, y: 900, width: 1440, height: 860)
        let frame = DetailsGeometry.frame(in: visible, replacing: position)
        #expect(frame.width == 360 && frame.height == 860)
        #expect(frame.minY == visible.minY)
        #expect(frame.minX == (position == .right ? visible.maxX - 360 : visible.minX))
        #expect(visible.contains(frame))
    }

    @Test func `physically narrow display clamps width`() {
        let visible = CGRect(x: 20, y: -100, width: 300, height: 700)
        #expect(DetailsGeometry.frame(in: visible, replacing: .right) == visible)
    }
}

struct ReservationTransitionTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let main = Reservation(frame: CGRect(x: 0, y: 0, width: 200, height: 900), edge: .left, role: .main)
    let details = Reservation(frame: CGRect(x: 0, y: 0, width: 360, height: 900), edge: .left, role: .details)

    private func decision(
        _ window: CGRect, _ baselines: WindowBaselines? = nil, from: Reservation?, to: Reservation?,
        mode: WindowAvoidanceMode = .clip
    ) -> ReservationTransition.Decision {
        ReservationTransition.decide(
            window: window, baselines: baselines, from: from, to: to,
            visibleFrame: screen, displayFrame: screen, mode: mode)
    }

    @Test func `one main to details decision retains both restore layers and actual readback`() throws {
        let original = CGRect(x: 0, y: 40, width: 1000, height: 700)
        let afterMain = CGRect(x: 208, y: 40, width: 792, height: 700)
        let baseline = WindowBaselines(main: original, accepted: afterMain)
        let result = decision(afterMain, baseline, from: main, to: details)
        guard case .move(let move) = result else {
            Issue.record("Expected a push")
            return
        }
        #expect(move.reason == .push)
        #expect(move.frame == CGRect(x: 368, y: 40, width: 632, height: 700))
        #expect(move.main == original && move.details == afterMain)
        let readback = CGRect(x: 368, y: 40, width: 650, height: 700)
        let kept = try #require(move.baselines(accepted: readback))
        #expect(kept.accepted == readback)
        guard case .move(let restored) = decision(readback, kept, from: details, to: nil) else {
            Issue.record("Expected earliest restoration")
            return
        }
        #expect(restored.frame == original && restored.baselines(accepted: original) == nil)
    }

    @Test func `clear windows do not expand when main is wider than details`() {
        let wideMain = Reservation(frame: CGRect(x: 0, y: 0, width: 500, height: 900), edge: .left, role: .main)
        let window = CGRect(x: 508, y: 50, width: 700, height: 600)
        #expect(decision(window, from: wideMain, to: details) == .leave(nil))
    }

    @Test func `changed unsnapped windows keep user geometry and lose restore claims`() {
        let accepted = CGRect(x: 400, y: 50, width: 700, height: 600)
        let moved = CGRect(x: 500, y: 100, width: 650, height: 600)
        let baseline = WindowBaselines(main: screen, details: screen, accepted: accepted)
        #expect(decision(moved, baseline, from: details, to: main) == .leave(nil))
        #expect(decision(moved, baseline, from: details, to: nil) == .leave(nil))
    }

    @Test(arguments: [CGFloat(0), 8])
    func `new or resized snapped windows follow on close preserving far edge and gap`(gap: CGFloat) {
        let window = CGRect(x: 360 + gap, y: 100, width: 600, height: 500)
        guard case .move(let move) = decision(window, from: details, to: main) else {
            Issue.record("Expected edge follow")
            return
        }
        #expect(move.reason == .follow)
        #expect(move.frame.minX == 200 + gap)
        #expect(move.frame.maxX == window.maxX)
        #expect(move.frame.minY == window.minY && move.frame.height == window.height)
        #expect(move.baselines(accepted: move.frame) == nil)
    }

    @Test func `edge follow takes priority over whole frame restoration`() {
        let before = CGRect(x: 208, y: 30, width: 600, height: 700)
        let accepted = CGRect(x: 368, y: 100, width: 600, height: 500)
        let baseline = WindowBaselines(details: before, accepted: accepted)
        guard case .move(let move) = decision(accepted, baseline, from: details, to: main) else {
            Issue.record("Expected edge follow")
            return
        }
        #expect(move.frame.minX == 208)
        #expect(move.frame.maxX == accepted.maxX)
        #expect(move.frame.minY == accepted.minY && move.frame.height == accepted.height)
    }

    @Test func `right snapped edge mirrors left and retains opposite edge`() {
        let rightDetails = Reservation(
            frame: CGRect(x: 1080, y: 0, width: 360, height: 900), edge: .right, role: .details)
        let rightMain = Reservation(frame: CGRect(x: 1240, y: 0, width: 200, height: 900), edge: .right, role: .main)
        let window = CGRect(x: 400, y: 50, width: 672, height: 600)
        guard case .move(let move) = decision(window, from: rightDetails, to: rightMain) else {
            Issue.record("Expected mirrored follow")
            return
        }
        #expect(move.frame.maxX == 1232)
        #expect(move.frame.minX == window.minX)
    }

    @Test(arguments: [PanelPosition.top, .bottom])
    func `bar return follows screen edge while clearing returning bar`(edge: PanelPosition) {
        let bar = Reservation(
            frame: CGRect(x: 0, y: edge == .top ? 0 : 840, width: 1440, height: 60), edge: edge, role: .main)
        let window = CGRect(x: 360, y: 0, width: 800, height: 900)
        guard case .move(let move) = decision(window, from: details, to: bar) else {
            Issue.record("Expected bar follow")
            return
        }
        #expect(move.frame.minX == 0 && move.frame.maxX == window.maxX)
        #expect(!move.frame.intersects(bar.frame))
    }

    @Test func `cross display window cannot gain edge follow without baseline`() {
        let window = CGRect(x: 360, y: -200, width: 600, height: 500)
        #expect(decision(window, from: details, to: main) == .leave(nil))
    }

    @Test func `avoidance off drops ledger and makes no move even for restore`() {
        let window = CGRect(x: 368, y: 40, width: 700, height: 600)
        let baseline = WindowBaselines(main: screen, details: screen, accepted: window)
        #expect(decision(window, baseline, from: details, to: nil, mode: .off) == .leave(nil))
        #expect(decision(window, baseline, from: details, to: main, mode: .off) == .leave(nil))
    }

    @Test(arguments: [CGFloat(-1440), 0, 1440])
    func `reservation handoff is invariant under display translation`(offset: CGFloat) {
        let localWindow = CGRect(x: 208, y: 50, width: 792, height: 700)
        let shifted = ReservationTransition.decide(
            window: localWindow.offsetBy(dx: offset, dy: -900), baselines: nil,
            from: Reservation(frame: main.frame.offsetBy(dx: offset, dy: -900), edge: .left, role: .main),
            to: Reservation(frame: details.frame.offsetBy(dx: offset, dy: -900), edge: .left, role: .details),
            visibleFrame: screen.offsetBy(dx: offset, dy: -900),
            displayFrame: screen.offsetBy(dx: offset, dy: -900), mode: .clip)
        guard case .move(let move) = shifted else {
            Issue.record("Expected push")
            return
        }
        #expect(move.frame == CGRect(x: 368 + offset, y: -850, width: 632, height: 700))
        #expect(move.details == localWindow.offsetBy(dx: offset, dy: -900))
    }

    @Test func `unchanged unsnapped window restores details baseline retaining main baseline`() {
        let original = CGRect(x: 0, y: 30, width: 900, height: 700)
        let beforeDetails = CGRect(x: 220, y: 30, width: 680, height: 700)
        let accepted = CGRect(x: 400, y: 30, width: 500, height: 700)
        let baseline = WindowBaselines(main: original, details: beforeDetails, accepted: accepted)
        guard case .move(let move) = decision(accepted, baseline, from: details, to: main) else {
            Issue.record("Expected unchanged restoration")
            return
        }
        #expect(move.reason == .restore && move.frame == beforeDetails)
        #expect(move.main == original && move.details == nil)
    }

    @Test func `restore tolerance checks position and size independently`() {
        let frame = CGRect(x: 400, y: 50, width: 700, height: 600)
        #expect(WindowFrames.isUnchanged(frame.offsetBy(dx: 2, dy: -2), since: frame))
        #expect(!WindowFrames.isUnchanged(frame.offsetBy(dx: 3, dy: 0), since: frame))
        #expect(!WindowFrames.isUnchanged(CGRect(x: 400, y: 50, width: 703, height: 600), since: frame))
    }
}

extension ReservationTransitionTests {
    @Test func `unchanged automatically pushed unsnapped contact restores instead of pulling outward`() throws {
        let before = CGRect(x: 250, y: 50, width: 600, height: 700)
        let opened = decision(before, from: main, to: details, mode: .smart)
        guard case .move(let pushed) = opened else {
            Issue.record("Expected push")
            return
        }
        #expect(pushed.frame.minX == 368)
        let ledger = try #require(pushed.baselines(accepted: pushed.frame))
        guard case .move(let closed) = decision(pushed.frame, ledger, from: details, to: main, mode: .smart)
        else {
            Issue.record("Expected restore")
            return
        }
        #expect(closed.reason == .restore && closed.frame == before)
    }

    @Test func `manual contact follows even with an obsolete unsnapped restore baseline`() {
        let before = CGRect(x: 250, y: 50, width: 600, height: 700)
        let accepted = CGRect(x: 368, y: 50, width: 600, height: 700)
        let resized = CGRect(x: 368, y: 100, width: 500, height: 600)
        let baseline = WindowBaselines(details: before, accepted: accepted)
        guard case .move(let moved) = decision(resized, baseline, from: details, to: main)
        else {
            Issue.record("Expected follow")
            return
        }
        #expect(moved.reason == .follow && moved.frame.minX == 208 && moved.frame.maxX == resized.maxX)
        #expect(moved.main == nil && moved.details == nil)
    }

    @Test(arguments: [PanelPosition.top, .bottom])
    func `bar takeover frees the old axis in one decision and closing restores both layers`(edge: PanelPosition) throws
    {
        let bar = Reservation(
            frame: CGRect(x: 0, y: edge == .top ? 0 : 840, width: 1440, height: 60), edge: edge, role: .main)
        let original = CGRect(x: 50, y: 0, width: 1000, height: 900)
        let afterBar = CGRect(x: 50, y: edge == .top ? 68 : 0, width: 1000, height: 832)
        let baseline = WindowBaselines(main: original, accepted: afterBar)
        guard case .move(let opened) = decision(afterBar, baseline, from: bar, to: details)
        else {
            Issue.record("Expected takeover")
            return
        }
        #expect(opened.frame == CGRect(x: 368, y: 0, width: 682, height: 900))
        #expect(opened.main == original && opened.details == original)
        let layer = try #require(opened.baselines(accepted: opened.frame))
        guard case .move(let closed) = decision(opened.frame, layer, from: details, to: bar)
        else {
            Issue.record("Expected bar restore")
            return
        }
        #expect(closed.frame == afterBar && closed.main == original && closed.details == nil)
        let mainLayer = try #require(closed.baselines(accepted: closed.frame))
        guard case .move(let hidden) = decision(closed.frame, mainLayer, from: bar, to: nil)
        else {
            Issue.record("Expected full restore")
            return
        }
        #expect(hidden.frame == original)
    }

    @Test func `main resize replans from earliest frame while user edits expire the old baseline`() throws {
        let original = CGRect(x: 0, y: 50, width: 1000, height: 700)
        let accepted = CGRect(x: 208, y: 50, width: 792, height: 700)
        let narrow = Reservation(frame: CGRect(x: 0, y: 0, width: 100, height: 900), edge: .left, role: .main)
        let baseline = WindowBaselines(main: original, accepted: accepted)
        guard case .move(let resized) = decision(accepted, baseline, from: main, to: narrow)
        else {
            Issue.record("Expected resize")
            return
        }
        #expect(resized.frame == CGRect(x: 108, y: 50, width: 892, height: 700))
        #expect(resized.main == original)
        let edited = accepted.offsetBy(dx: 30, dy: 10)
        #expect(decision(edited, baseline, from: main, to: narrow) == .leave(nil))
    }

    @Test func `new bar contact stores the unclipped baseline for a later global hide`() throws {
        let bar = Reservation(frame: CGRect(x: 0, y: 0, width: 1440, height: 60), edge: .top, role: .main)
        let window = CGRect(x: 360, y: 0, width: 800, height: 900)
        guard case .move(let closed) = decision(window, from: details, to: bar)
        else {
            Issue.record("Expected follow")
            return
        }
        #expect(closed.reason == .follow)
        let layer = try #require(closed.baselines(accepted: closed.frame))
        guard case .move(let hidden) = decision(closed.frame, layer, from: bar, to: nil)
        else {
            Issue.record("Expected bar release")
            return
        }
        #expect(hidden.frame == CGRect(x: 0, y: 0, width: 1160, height: 900))
    }
}

/// What a window the window manager placed on purpose is, and isn't, avoidance's to move: *keep clear* applies to
/// it like any other window, *put it back* never does.
struct DeliberatePlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let main = Reservation(frame: CGRect(x: 0, y: 0, width: 200, height: 900), edge: .left, role: .main)
    let details = Reservation(frame: CGRect(x: 0, y: 0, width: 360, height: 900), edge: .left, role: .details)

    private func decision(
        _ window: CGRect, _ baselines: WindowBaselines? = nil, from: Reservation?, to: Reservation?,
        onPurpose: Bool
    ) -> ReservationTransition.Decision {
        ReservationTransition.decide(
            window: window, baselines: baselines, from: from, to: to, visibleFrame: screen, displayFrame: screen,
            mode: .clip, isPlacedOnPurpose: onPurpose)
    }

    /// A tile that happens to land where avoidance had pushed the window: hiding the panels used to put it back,
    /// which is why the manager had to delete avoidance's row after every press.
    @Test func `hiding the panels leaves a tile where it is, however much avoidance remembers`() {
        let tile = CGRect(x: 208, y: 0, width: 616, height: 900)
        let remembered = WindowBaselines(main: CGRect(x: 0, y: 100, width: 600, height: 400), accepted: tile)
        #expect(decision(tile, remembered, from: main, to: nil, onPurpose: false) != .leave(nil))
        #expect(decision(tile, remembered, from: main, to: nil, onPurpose: true) == .leave(nil))
    }

    /// Keeping clear is unconditional, and the way back it leaves is to the tile, not to where the window was
    /// before the manager ever touched it.
    @Test func `a strip growing into a tile still pushes it, with a fresh way back to the tile`() throws {
        let wider = Reservation(frame: CGRect(x: 0, y: 0, width: 400, height: 900), edge: .left, role: .main)
        let tile = CGRect(x: 208, y: 0, width: 616, height: 900)
        let remembered = WindowBaselines(main: CGRect(x: 0, y: 100, width: 600, height: 400), accepted: tile)
        guard case .move(let move) = decision(tile, remembered, from: main, to: wider, onPurpose: true) else {
            Issue.record("a strip that grows into a tile has to push it")
            return
        }
        #expect(move.reason == .push)
        #expect(move.frame.minX == 408)
        // The way back is the tile, so hiding the panel returns it there rather than to the pre-manager frame.
        let baselines = try #require(move.baselines(accepted: move.frame))
        #expect(baselines.main == tile)
        #expect(
            decision(move.frame, baselines, from: wider, to: nil, onPurpose: false)
                == .move(.init(reason: .restore, frame: tile)))
    }

    /// Following a closing details panel's edge is a way of putting a window back, so it isn't avoidance's to do to
    /// a window someone placed. The returning strip still pushes it if it covers it.
    @Test func `a tile doesn't follow a closing details panel's edge`() {
        let snapped = CGRect(x: 368, y: 0, width: 600, height: 900)
        #expect(decision(snapped, from: details, to: main, onPurpose: true) == .leave(nil))
        // Without the intent it follows the edge back, as a snapped window does.
        guard case .move(let move) = decision(snapped, from: details, to: main, onPurpose: false) else {
            Issue.record("a snapped window follows the edge back")
            return
        }
        #expect(move.reason == .follow)
    }
}
