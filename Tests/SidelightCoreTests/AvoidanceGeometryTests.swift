import CoreGraphics
import Testing

@testable import SidelightCore

struct AvoidanceGeometryTests {
    // A 1000×800 screen with a 20 pt menu bar; panel 300 pt wide on the left.
    let visible = CGRect(x: 0, y: 20, width: 1000, height: 780)
    let leftPanel = CGRect(x: 0, y: 20, width: 300, height: 780)

    @Test(arguments: [PanelPosition.left, .right, .top, .bottom])
    func `canonical space round-trips`(edge: PanelPosition) {
        let rect = CGRect(x: 12, y: 34, width: 560, height: 78)
        #expect(AvoidanceGeometry.restored(AvoidanceGeometry.canonical(rect, edge: edge), edge: edge) == rect)
    }

    @Test func `windows clear of the panel are left alone`() {
        let window = CGRect(x: 400, y: 100, width: 300, height: 300)
        #expect(plan(window, mode: .smart) == nil)
    }

    @Test func `off never moves anything`() {
        let window = CGRect(x: 100, y: 100, width: 300, height: 300)
        #expect(plan(window, mode: .off) == nil)
    }

    @Test func `shift moves the window past the panel and keeps its size`() throws {
        let window = CGRect(x: 100, y: 100, width: 300, height: 300)
        let result = try #require(plan(window, mode: .shift))
        #expect(result.action == .shift)
        #expect(result.frame == CGRect(x: 308, y: 100, width: 300, height: 300))
        #expect(result.shiftFallback == nil)
    }

    @Test func `shift never pushes the window past the screen edge`() throws {
        let window = CGRect(x: 100, y: 100, width: 900, height: 300)
        let result = try #require(plan(window, mode: .shift))
        #expect(result.frame == CGRect(x: 308, y: 100, width: 692, height: 300))
    }

    @Test func `clip keeps the far edge`() throws {
        let window = CGRect(x: 0, y: 20, width: 1000, height: 780)
        let result = try #require(plan(window, mode: .clip))
        #expect(result.action == .clip)
        #expect(result.frame == CGRect(x: 308, y: 20, width: 692, height: 780))
        #expect(result.shiftFallback != nil)
    }

    @Test func `clip that would leave less than 40 percent shifts instead`() throws {
        let window = CGRect(x: 100, y: 100, width: 300, height: 300)  // only 92 of 300 pt would remain
        let result = try #require(plan(window, mode: .clip))
        #expect(result.action == .shift)
    }

    @Test func `smart clips snapped windows and shifts floating ones`() throws {
        let snapped = CGRect(x: 1, y: 20, width: 800, height: 780)
        let floating = CGRect(x: 120, y: 100, width: 600, height: 400)
        #expect(try #require(plan(snapped, mode: .smart)).action == .clip)
        #expect(try #require(plan(floating, mode: .smart)).action == .shift)
    }

    @Test func `right edge mirrors the left edge`() throws {
        let panel = CGRect(x: 700, y: 20, width: 300, height: 780)
        let window = CGRect(x: 600, y: 100, width: 300, height: 300)
        let result = try #require(
            AvoidanceGeometry.plan(window: window, panel: panel, visibleFrame: visible, edge: .right, mode: .shift)
        )
        #expect(result.frame == CGRect(x: 392, y: 100, width: 300, height: 300))
    }

    @Test func `top bar pushes windows down`() throws {
        let panel = CGRect(x: 0, y: 20, width: 1000, height: 44)
        let window = CGRect(x: 100, y: 30, width: 400, height: 300)
        let result = try #require(
            AvoidanceGeometry.plan(window: window, panel: panel, visibleFrame: visible, edge: .top, mode: .shift)
        )
        #expect(result.frame == CGRect(x: 100, y: 72, width: 400, height: 300))
    }

    @Test func `bottom bar clips window height`() throws {
        let panel = CGRect(x: 0, y: 756, width: 1000, height: 44)
        let window = CGRect(x: 0, y: 20, width: 1000, height: 780)
        let result = try #require(
            AvoidanceGeometry.plan(window: window, panel: panel, visibleFrame: visible, edge: .bottom, mode: .clip)
        )
        #expect(result.frame == CGRect(x: 0, y: 20, width: 1000, height: 728))
    }

    @Test func `detects a refused clip`() {
        let requested = CGRect(x: 308, y: 20, width: 400, height: 500)
        #expect(
            AvoidanceGeometry.clipWasRefused(
                requested: requested, actual: requested.insetBy(dx: -50, dy: 0), edge: .left))
        #expect(!AvoidanceGeometry.clipWasRefused(requested: requested, actual: requested, edge: .left))
    }

    @Test func `converts Cocoa rects to Accessibility space`() {
        let cocoa = CGRect(x: 10, y: 0, width: 100, height: 50)
        #expect(
            AvoidanceGeometry.accessibilityRect(fromCocoa: cocoa, primaryScreenHeight: 800)
                == CGRect(x: 10, y: 750, width: 100, height: 50)
        )
    }

    private func plan(_ window: CGRect, mode: WindowAvoidanceMode) -> AvoidancePlan? {
        AvoidanceGeometry.plan(window: window, panel: leftPanel, visibleFrame: visible, edge: .left, mode: mode)
    }
}
