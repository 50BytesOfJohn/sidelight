import CoreGraphics
import Testing

@testable import SidelightCore

struct OwnWindowPlacementTests {
    // A 1440×900 screen with a 30 pt menu bar along the top, in Cocoa space (y up).
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 870)
    let leftPanel = CGRect(x: 0, y: 0, width: 300, height: 870)
    let rightPanel = CGRect(x: 1140, y: 0, width: 300, height: 870)
    let minimum = CGSize(width: 700, height: 500)

    @Test func `without a panel the whole visible frame is free`() {
        #expect(OwnWindowPlacement.freeFrame(in: visible, beside: []) == visible)
    }

    @Test func `a side panel leaves the rest of the screen less the gap`() {
        #expect(
            OwnWindowPlacement.freeFrame(in: visible, beside: [leftPanel])
                == CGRect(x: 308, y: 0, width: 1132, height: 870))
        #expect(
            OwnWindowPlacement.freeFrame(in: visible, beside: [rightPanel])
                == CGRect(x: 0, y: 0, width: 1132, height: 870))
    }

    @Test func `a bar leaves the space below it`() {
        let bar = CGRect(x: 0, y: 830, width: 1440, height: 40)
        #expect(
            OwnWindowPlacement.freeFrame(in: visible, beside: [bar]) == CGRect(x: 0, y: 0, width: 1440, height: 822))
    }

    @Test func `a panel on another screen frees nothing`() {
        let elsewhere = CGRect(x: 2000, y: 0, width: 300, height: 870)
        #expect(OwnWindowPlacement.freeFrame(in: visible, beside: [elsewhere]) == visible)
    }

    @Test func `a window that already fits stays put`() {
        let window = CGRect(x: 400, y: 100, width: 800, height: 600)
        #expect(fit(window, beside: leftPanel) == window)
    }

    @Test func `a covered window moves out from under the panel at its size`() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(fit(window, beside: leftPanel) == CGRect(x: 308, y: 100, width: 800, height: 600))
        #expect(
            fit(CGRect(x: 500, y: 100, width: 800, height: 600), beside: rightPanel)
                == CGRect(x: 332, y: 100, width: 800, height: 600))
    }

    @Test func `a window wider than the free space shrinks to it`() {
        let window = CGRect(x: 100, y: 100, width: 1300, height: 600)
        #expect(fit(window, beside: leftPanel) == CGRect(x: 308, y: 100, width: 1132, height: 600))
    }

    @Test func `a window that can't shrink enough sits beside the panel and overlaps as little as it can`() {
        let narrow = CGRect(x: 0, y: 0, width: 900, height: 870)
        let panel = CGRect(x: 0, y: 0, width: 300, height: 870)
        let window = CGRect(x: 50, y: 100, width: 800, height: 600)
        // 592 pt are free; the window can't go below 700, so it starts beside the panel and the screen edge
        // pulls it back over the panel only by what doesn't fit.
        #expect(
            OwnWindowPlacement.fit(
                window, minimumSize: minimum, in: OwnWindowPlacement.freeFrame(in: narrow, beside: [panel]),
                visibleFrame: narrow) == CGRect(x: 200, y: 100, width: 700, height: 600))
    }

    private func fit(_ window: CGRect, beside panel: CGRect) -> CGRect {
        OwnWindowPlacement.fit(
            window, minimumSize: minimum, in: OwnWindowPlacement.freeFrame(in: visible, beside: [panel]),
            visibleFrame: visible)
    }
}
