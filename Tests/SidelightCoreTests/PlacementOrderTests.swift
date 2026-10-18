import CoreGraphics
import Testing

@testable import SidelightCore

/// The no-blink property, as a property: for every tile, every panel edge and every way a window can be sitting
/// before the press, no frame the placement passes through covers the panel.
struct PlacementOrderTests {
    // A 1000×800 screen with a 20 pt menu bar.
    let visible = CGRect(x: 0, y: 20, width: 1000, height: 780)

    private func panel(_ edge: PanelPosition) -> Reservation {
        let frame: CGRect =
            switch edge {
            case .left: CGRect(x: 0, y: 20, width: 300, height: 780)
            case .right: CGRect(x: 700, y: 20, width: 300, height: 780)
            case .top: CGRect(x: 0, y: 20, width: 1000, height: 60)
            case .bottom: CGRect(x: 0, y: 740, width: 1000, height: 60)
            }
        return Reservation(frame: frame, edge: edge, role: .main)
    }

    private func area(_ edge: PanelPosition, padding: CGFloat = 8) -> WorkArea {
        WorkArea(visibleFrame: visible, reservations: [panel(edge)], padding: padding)
    }

    /// Every frame the window is composited at along the way, in order.
    private func frames(from current: CGRect, to target: CGRect, in area: WorkArea) -> [CGRect] {
        var frame = current
        return PlacementOrder.writes(from: current, to: target, in: area).map { write in
            switch write {
            case .position(let origin): frame = CGRect(origin: origin, size: frame.size)
            case .size(let size): frame = CGRect(origin: frame.origin, size: size)
            }
            return frame
        }
    }

    @Test(arguments: WindowAction.allCases.filter { $0.unitRect() != nil }, PanelPosition.allCases)
    func `no frame along the way covers the panel`(action: WindowAction, edge: PanelPosition) throws {
        let area = area(edge)
        let starts = [
            // Under the panel, which is where a window avoidance never moved sits.
            CGRect(x: 0, y: 20, width: 500, height: 400),
            // Straddling its inner edge.
            CGRect(x: 250, y: 100, width: 500, height: 600),
            // Clear of it, filling the far side.
            CGRect(x: 320, y: 40, width: 660, height: 740),
            // Small, clear, and about to grow.
            CGRect(x: 400, y: 300, width: 200, height: 150),
            // The whole screen, under a panel on any edge at once.
            visible,
        ]
        for step in 0..<3 {
            let tile = try #require(WindowLayout.frame(for: action, step: step, in: area.rect, gap: 8))
            #expect(area.isClear(tile), "the tile itself: \(tile)")
            for start in starts {
                let path = frames(from: start, to: tile, in: area)
                let widest = CGSize(
                    width: max(start.width, tile.width), height: max(start.height, tile.height))
                guard area.safeOrigin(for: widest) != nil else {
                    // The documented exception: the window is too big for the room beside the panel at one of the
                    // two sizes, so some frame along the way has to overhang something. It still never covers more
                    // than the window already did.
                    let before = PlacementOrder.covered(start, in: area)
                    for frame in path {
                        #expect(
                            PlacementOrder.covered(frame, in: area) <= before,
                            "\(action) step \(step) from \(start): \(frame)")
                    }
                    continue
                }
                for frame in path {
                    #expect(area.isClear(frame), "\(action) step \(step) from \(start): \(frame)")
                }
            }
        }
    }

    @Test(arguments: PanelPosition.allCases)
    func `a window under a leading panel moves before it resizes`(edge: PanelPosition) throws {
        let area = area(edge)
        let under = CGRect(x: 0, y: 20, width: 500, height: 400)
        let tile = try #require(WindowLayout.frame(for: .maximize, in: area.rect, gap: 8))
        // Size first would leave the window at its old origin — under the panel on a leading edge.
        #expect(PlacementOrder.writes(from: under, to: tile, in: area).first == .position(tile.origin))
    }

    @Test func `a window growing past a trailing panel resizes before it moves`() throws {
        let area = area(.right)
        // Clear of the panel, and nearly as wide as the screen: moved to the left half's origin first, its old
        // width would reach under the panel, so this is the case size-first is for.
        let wide = CGRect(x: 0, y: 100, width: 695, height: 600)
        #expect(area.isClear(wide))
        let tile = try #require(WindowLayout.frame(for: .leftHalf, in: area.rect, gap: 8))
        #expect(!area.isClear(CGRect(origin: tile.origin, size: wide.size)))
        #expect(PlacementOrder.writes(from: wide, to: tile, in: area) == [.size(tile.size), .position(tile.origin)])
    }

    @Test func `with neither order clear the window goes by way of a safe origin`() throws {
        // A panel on both edges, and a window over the left one on its way to a right half: the right half's
        // origin at its old width reaches the right panel, and its new width at its old origin still covers the
        // left one. Neither two-write order is clear, and there's room between the two for both sizes.
        let both = WorkArea(visibleFrame: visible, reservations: [panel(.left), panel(.right)], padding: 8)
        let over = CGRect(x: 250, y: 100, width: 200, height: 300)
        let tile = try #require(WindowLayout.frame(for: .rightHalf, in: both.rect, gap: 8))
        #expect(!both.isClear(CGRect(origin: tile.origin, size: over.size)))
        #expect(!both.isClear(CGRect(origin: over.origin, size: tile.size)))
        let writes = PlacementOrder.writes(from: over, to: tile, in: both)
        #expect(writes.count == 3)
        #expect(writes.last == .position(tile.origin))
        for frame in frames(from: over, to: tile, in: both) { #expect(both.isClear(frame), "\(frame)") }
        // Two writes are enough whenever one order is clear.
        #expect(PlacementOrder.writes(from: over, to: tile, in: area(.left)).count == 2)
    }

    @Test func `a window too big for the display takes the order that covers less`() {
        let area = area(.left)
        let huge = CGRect(x: 0, y: 20, width: 2000, height: 780)
        let target = CGRect(x: 308, y: 28, width: 1800, height: 764)
        let writes = PlacementOrder.writes(from: huge, to: target, in: area)
        #expect(writes.count == 2)
        // The new origin is already past the panel, so moving first covers nothing extra.
        #expect(writes.first == .position(target.origin))
    }

    @Test func `a write that changes nothing is left out`() {
        let area = area(.left)
        let frame = CGRect(x: 400, y: 100, width: 300, height: 200)
        #expect(PlacementOrder.writes(from: frame, to: frame, in: area).isEmpty)
        // Within a point of what it already has counts as nothing.
        #expect(PlacementOrder.writes(from: frame, to: frame.offsetBy(dx: 1, dy: -1), in: area).isEmpty)
        let moved = frame.offsetBy(dx: 40, dy: 0)
        #expect(PlacementOrder.writes(from: frame, to: moved, in: area) == [.position(moved.origin)])
        let resized = CGRect(origin: frame.origin, size: CGSize(width: 500, height: 200))
        #expect(PlacementOrder.writes(from: frame, to: resized, in: area) == [.size(resized.size)])
    }

    @Test(arguments: PanelPosition.allCases)
    func `a leading-anchored tile the app refuses needs no correction`(edge: PanelPosition) throws {
        let area = area(edge)
        // A corner tile is anchored to the work area's own corner along both axes, whichever way the panel lies.
        let tile = try #require(WindowLayout.frame(for: .topLeft, in: area.rect, gap: 8))
        // The app insists on a size of its own: anchored to the edges the tile touches, it stays at the origin it
        // already has, so position-first leaves nothing more to write.
        let refused = CGSize(width: tile.width + 120, height: tile.height - 90)
        let anchored = WindowLayout.anchored(refused, for: .topLeft, tile: tile, in: area)
        #expect(anchored.origin == tile.origin)
        #expect(area.isClear(anchored))
        #expect(
            PlacementOrder.writes(from: CGRect(origin: tile.origin, size: refused), to: anchored, in: area).isEmpty)
    }

    @Test func `a trailing tile the app refuses is corrected with one move`() throws {
        let area = area(.left)
        let tile = try #require(WindowLayout.frame(for: .rightHalf, in: area.rect, gap: 8))
        let refused = CGSize(width: tile.width + 160, height: tile.height)
        let anchored = WindowLayout.anchored(refused, for: .rightHalf, tile: tile, in: area)
        // Its far edge is still the tile's, so only the origin changed — one message, not another whole frame.
        #expect(anchored.maxX == tile.maxX)
        #expect(anchored.size == refused)
        #expect(area.isClear(anchored))
        #expect(
            PlacementOrder.writes(from: CGRect(origin: tile.origin, size: refused), to: anchored, in: area)
                == [.position(anchored.origin)])
    }

    @Test(arguments: PanelPosition.allCases)
    func `a window too big for the room beside the panel overflows the far edge instead`(edge: PanelPosition) {
        let area = area(edge)
        let tile = area.rect
        // Wider and taller than the whole work area: it has to overhang something, and it isn't the panel.
        let refused = CGSize(width: area.visibleFrame.width, height: area.visibleFrame.height)
        let anchored = WindowLayout.anchored(refused, for: .maximize, tile: tile, in: area)
        #expect(area.isClear(anchored), "\(anchored)")
    }
}
