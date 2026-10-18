import CoreGraphics
import Testing

@testable import SidelightCore

struct OwnWindowPlacementTests {
    // A 1440×900 screen with a 30 pt menu bar along the top, in Accessibility space (y down).
    let visible = CGRect(x: 0, y: 30, width: 1440, height: 870)
    let left = Reservation(frame: CGRect(x: 0, y: 30, width: 300, height: 870), edge: .left, role: .main)
    let right = Reservation(frame: CGRect(x: 1140, y: 30, width: 300, height: 870), edge: .right, role: .main)
    let minimum = CGSize(width: 700, height: 500)

    @Test func `without a panel the whole visible frame is free`() {
        #expect(free() == visible)
    }

    @Test func `a side panel leaves the rest of the screen less the clearance`() {
        #expect(free(left) == CGRect(x: 308, y: 30, width: 1132, height: 870))
        #expect(free(right) == CGRect(x: 0, y: 30, width: 1132, height: 870))
    }

    @Test func `a bar leaves the space below it`() {
        let bar = Reservation(frame: CGRect(x: 0, y: 30, width: 1440, height: 40), edge: .top, role: .main)
        #expect(free(bar) == CGRect(x: 0, y: 78, width: 1440, height: 822))
    }

    @Test func `a panel on another screen frees nothing`() {
        let elsewhere = Reservation(
            frame: CGRect(x: 2000, y: 30, width: 300, height: 870), edge: .left, role: .main)
        #expect(free(elsewhere) == visible)
    }

    @Test func `a window that already fits stays put`() {
        let window = CGRect(x: 400, y: 130, width: 800, height: 600)
        #expect(fit(window, beside: left) == window)
    }

    @Test func `a covered window moves out from under the panel at its size`() {
        #expect(
            fit(CGRect(x: 100, y: 130, width: 800, height: 600), beside: left)
                == CGRect(x: 308, y: 130, width: 800, height: 600))
        #expect(
            fit(CGRect(x: 500, y: 130, width: 800, height: 600), beside: right)
                == CGRect(x: 332, y: 130, width: 800, height: 600))
    }

    @Test func `a window wider than the free space shrinks to it`() {
        #expect(
            fit(CGRect(x: 100, y: 130, width: 1300, height: 600), beside: left)
                == CGRect(x: 308, y: 130, width: 1132, height: 600))
    }

    @Test func `a window that can't shrink enough sits beside the panel and overlaps as little as it can`() {
        let narrow = CGRect(x: 0, y: 0, width: 900, height: 870)
        let panel = Reservation(frame: CGRect(x: 0, y: 0, width: 300, height: 870), edge: .left, role: .main)
        let area = WorkArea(visibleFrame: narrow, reservations: [panel])
        // 592 pt are free; the window can't go below 700, so it starts beside the panel and the screen edge
        // pulls it back over the panel only by what doesn't fit.
        #expect(
            OwnWindowPlacement.fit(
                CGRect(x: 50, y: 100, width: 800, height: 600), minimumSize: minimum, in: area.clear,
                visibleFrame: narrow) == CGRect(x: 200, y: 100, width: 700, height: 600))
    }

    private func free(_ reservations: Reservation...) -> CGRect {
        WorkArea(visibleFrame: visible, reservations: reservations).clear
    }

    private func fit(_ window: CGRect, beside panel: Reservation) -> CGRect {
        OwnWindowPlacement.fit(
            window, minimumSize: minimum, in: free(panel), visibleFrame: visible)
    }
}
