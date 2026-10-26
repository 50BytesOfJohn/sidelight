import CoreGraphics
import Testing

@testable import SidelightCore

/// Windows side by side move together as a strip's edge moves, so a layout survives the details panel opening and
/// closing.
struct LayoutReflowTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let main = Reservation(frame: CGRect(x: 0, y: 0, width: 200, height: 900), edge: .left, role: .main)
    let details = Reservation(frame: CGRect(x: 0, y: 0, width: 360, height: 900), edge: .left, role: .details)

    /// The window manager's quarters beside the side panel, `gap` apart.
    private func grid(gap: CGFloat = 8, from start: CGFloat = 208) -> [CGRect] {
        let split = ((start + 1440) / 2).rounded()
        let half = gap / 2
        return [
            CGRect(x: start, y: 0, width: split - half - start, height: 450 - half),
            CGRect(x: split + half, y: 0, width: 1440 - split - half, height: 450 - half),
            CGRect(x: start, y: 450 + half, width: split - half - start, height: 450 - half),
            CGRect(x: split + half, y: 450 + half, width: 1440 - split - half, height: 450 - half),
        ]
    }

    private func decide(
        _ windows: [ReservationTransition.Candidate], from: Reservation?, to: Reservation?,
        mode: WindowAvoidanceMode = .smart
    ) -> [ReservationTransition.Decision] {
        ReservationTransition.decide(
            windows, from: from, to: to, visibleFrame: screen, displayFrame: screen, mode: mode)
    }

    /// Where each window ends up, and what avoidance remembers of it, as if every app took what it was asked for.
    private func apply(
        _ decisions: [ReservationTransition.Decision], to windows: [ReservationTransition.Candidate]
    ) -> [ReservationTransition.Candidate] {
        zip(windows, decisions).map { window, decision in
            switch decision {
            case .leave(let baselines):
                return .init(frame: window.frame, baselines: baselines)
            case .move(let move):
                return .init(frame: move.frame, baselines: move.baselines(accepted: move.frame))
            }
        }
    }

    private func expectNoOverlaps(_ frames: [CGRect], sourceLocation: SourceLocation = #_sourceLocation) {
        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] {
                #expect(!frame.intersects(other), "\(frame) overlaps \(other)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test(arguments: [CGFloat(0), 8, 32])
    func `a grid opens and closes with the details panel as one`(gap: CGFloat) {
        let tiles = grid(gap: gap)
        let start = tiles.map { ReservationTransition.Candidate(frame: $0, isPlacedOnPurpose: true) }

        let opened = apply(decide(start, from: main, to: details), to: start)
        let frames = opened.map(\.frame)
        expectNoOverlaps(frames)
        #expect(frames.allSatisfy { !$0.intersects(details.frame) })
        // Columns stay columns, starting beside the details panel and ending where they did.
        #expect(frames[0].minX == 368 && frames[2].minX == 368)
        #expect(frames[1].minX == frames[3].minX && frames[0].maxX == frames[2].maxX)
        #expect(frames[1].maxX == 1440 && frames[3].maxX == 1440)
        // The window manager's gap stays the gap.
        #expect(frames[1].minX - frames[0].maxX == gap && frames[3].minX - frames[2].maxX == gap)
        // Rows don't change.
        #expect(zip(frames, tiles).allSatisfy { $0.minY == $1.minY && $0.height == $1.height })

        let closed = apply(decide(opened, from: details, to: main), to: opened)
        #expect(closed.map(\.frame) == tiles)
    }

    @Test func `a grid laid out beside the open details panel follows its edge back`() {
        // Not a tile, and nothing avoidance remembers: dragged there by hand, say.
        let tiles = grid(from: 368)
        let windows = tiles.map { ReservationTransition.Candidate(frame: $0) }
        let closed = apply(decide(windows, from: details, to: main), to: windows).map(\.frame)
        expectNoOverlaps(closed)
        #expect(closed[0].minX == 208 && closed[2].minX == 208)
        #expect(closed[1].minX == closed[3].minX && closed[0].maxX == closed[2].maxX)
        #expect(closed[1].maxX == 1440 && closed[3].maxX == 1440)
        #expect(closed[0].width > tiles[0].width && closed[1].width > tiles[1].width)
        #expect(closed[1].minX - closed[0].maxX == 8)
    }

    @Test func `showing the panel squeezes a full screen grid beside it`() {
        let tiles = grid(from: 0)
        let windows = tiles.map { ReservationTransition.Candidate(frame: $0) }
        let shown = apply(decide(windows, from: nil, to: main), to: windows)
        expectNoOverlaps(shown.map(\.frame))
        #expect(shown[0].frame.minX == 208 && shown[1].frame.maxX == 1440)
        // Hiding it again puts every window back.
        let hidden = apply(decide(shown, from: main, to: nil), to: shown)
        #expect(hidden.map(\.frame) == tiles)
    }

    @Test func `rows split in the same place stay aligned however they're grouped`() {
        // Three windows on top, two below, sharing the boundary at 824.
        let windows = [
            CGRect(x: 208, y: 0, width: 400, height: 450),
            CGRect(x: 608, y: 0, width: 216, height: 450),
            CGRect(x: 824, y: 0, width: 616, height: 450),
            CGRect(x: 208, y: 450, width: 616, height: 450),
            CGRect(x: 824, y: 450, width: 616, height: 450),
        ].map { ReservationTransition.Candidate(frame: $0) }
        let opened = apply(decide(windows, from: main, to: details), to: windows).map(\.frame)
        expectNoOverlaps(opened)
        #expect(opened[1].maxX == opened[2].minX)
        #expect(opened[2].minX == opened[4].minX && opened[3].maxX == opened[4].minX)
    }

    @Test func `a lone tile beside the side panel clips instead of sliding over its neighbourhood`() {
        let tile = CGRect(x: 208, y: 0, width: 616, height: 900)
        let decisions = decide([.init(frame: tile)], from: main, to: details)
        guard case .move(let move) = decisions[0] else {
            Issue.record("Expected a push")
            return
        }
        #expect(move.frame == CGRect(x: 368, y: 0, width: 456, height: 900))
    }

    @Test func `a window apart from the pushed one stays where it is`() {
        let pushed = CGRect(x: 208, y: 0, width: 600, height: 900)
        let apart = CGRect(x: 900, y: 0, width: 500, height: 900)
        let decisions = decide([.init(frame: pushed), .init(frame: apart)], from: main, to: details)
        #expect(decisions[1] == .leave(nil))
    }

    @Test(arguments: [WindowAvoidanceMode.shift, .clip])
    func `only smart mode moves windows together`(mode: WindowAvoidanceMode) {
        let windows = grid().map { ReservationTransition.Candidate(frame: $0) }
        let decisions = decide(windows, from: main, to: details, mode: mode)
        #expect(decisions[1] == .leave(nil) && decisions[3] == .leave(nil))
    }

    @Test func `a grid beside a right panel mirrors the left`() {
        let rightMain = Reservation(frame: CGRect(x: 1240, y: 0, width: 200, height: 900), edge: .right, role: .main)
        let rightDetails = Reservation(
            frame: CGRect(x: 1080, y: 0, width: 360, height: 900), edge: .right, role: .details)
        let tiles = [
            CGRect(x: 0, y: 0, width: 612, height: 900),
            CGRect(x: 620, y: 0, width: 612, height: 900),
        ]
        let windows = tiles.map { ReservationTransition.Candidate(frame: $0) }
        let opened = apply(decide(windows, from: rightMain, to: rightDetails), to: windows)
        expectNoOverlaps(opened.map(\.frame))
        #expect(opened[0].frame.minX == 0 && opened[1].frame.maxX == 1072)
        let closed = apply(decide(opened, from: rightDetails, to: rightMain), to: opened)
        #expect(closed.map(\.frame) == tiles)
    }

    @Test func `side by side means level and close`() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(ReservationTransition.areSideBySide(window, window.offsetBy(dx: 100, dy: 50)))
        #expect(ReservationTransition.areSideBySide(window, window.offsetBy(dx: 132, dy: 0)))
        #expect(!ReservationTransition.areSideBySide(window, window.offsetBy(dx: 140, dy: 0)))
        #expect(!ReservationTransition.areSideBySide(window, window.offsetBy(dx: 100, dy: 99)))
        #expect(!ReservationTransition.areSideBySide(window, window.offsetBy(dx: 50, dy: 0)))
    }
}
