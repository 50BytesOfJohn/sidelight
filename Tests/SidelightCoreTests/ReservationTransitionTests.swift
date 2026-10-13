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
        #expect(ReservationTransition.isUnchanged(frame.offsetBy(dx: 2, dy: -2), since: frame))
        #expect(!ReservationTransition.isUnchanged(frame.offsetBy(dx: 3, dy: 0), since: frame))
        #expect(!ReservationTransition.isUnchanged(CGRect(x: 400, y: 50, width: 703, height: 600), since: frame))
    }
}
