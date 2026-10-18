import CoreGraphics
import Testing

@testable import SidelightCore

struct WorkAreaTests {
    // A 1000×800 screen with a 20 pt menu bar.
    let visible = CGRect(x: 0, y: 20, width: 1000, height: 780)
    let leftPanel = Reservation(frame: CGRect(x: 0, y: 20, width: 300, height: 780), edge: .left, role: .main)

    @Test(arguments: PanelPosition.allCases)
    func `the keep-out is the strip plus the clearance on its inner edge`(edge: PanelPosition) {
        let frame = CGRect(x: 100, y: 200, width: 300, height: 400)
        let keepOut = Reservation(frame: frame, edge: edge, role: .main, clearance: 8).keepOut
        #expect(keepOut.contains(frame))
        let grown: CGRect =
            switch edge {
            case .left: CGRect(x: 100, y: 200, width: 308, height: 400)
            case .right: CGRect(x: 92, y: 200, width: 308, height: 400)
            case .top: CGRect(x: 100, y: 200, width: 300, height: 408)
            case .bottom: CGRect(x: 100, y: 192, width: 300, height: 408)
            }
        #expect(keepOut == grown)
    }

    @Test func `the clear frame is the visible frame less the keep-outs, with no padding`() {
        let area = WorkArea(visibleFrame: visible, reservations: [leftPanel], padding: 16)
        #expect(area.clear == CGRect(x: 308, y: 20, width: 692, height: 780))
        // Padding comes off the edges no panel took; beside the panel the clearance stands.
        #expect(area.rect == CGRect(x: 308, y: 36, width: 676, height: 748))
        #expect(WorkArea(visibleFrame: visible, reservations: []).clear == visible)
    }

    @Test func `a panel that doesn't reach the display reserves nothing`() {
        let elsewhere = Reservation(
            frame: CGRect(x: 2000, y: 20, width: 300, height: 780), edge: .left, role: .main)
        let area = WorkArea(visibleFrame: visible, reservations: [elsewhere], padding: 8)
        #expect(area.clear == visible)
        #expect(area.isClear(visible))
    }

    /// The property the window manager and window avoidance used to share by imitation: the frames the work area
    /// calls clear are exactly the ones avoidance leaves alone.
    @Test(arguments: PanelPosition.allCases)
    func `clear means avoidance has nothing to do, and the other way round`(edge: PanelPosition) {
        let panel: CGRect =
            switch edge {
            case .left: CGRect(x: 0, y: 20, width: 300, height: 780)
            case .right: CGRect(x: 700, y: 20, width: 300, height: 780)
            case .top: CGRect(x: 0, y: 20, width: 1000, height: 60)
            case .bottom: CGRect(x: 0, y: 740, width: 1000, height: 60)
            }
        let reservation = Reservation(frame: panel, edge: edge, role: .main)
        let area = WorkArea(visibleFrame: visible, reservations: [reservation], padding: 8)
        for x in stride(from: -100.0, through: 900.0, by: 100) {
            for y in stride(from: -40.0, through: 760.0, by: 100) {
                let window = CGRect(x: x, y: y, width: 260, height: 220)
                let plan = AvoidanceGeometry.plan(
                    window: window, panel: panel, visibleFrame: visible, edge: edge, mode: .shift,
                    clearance: reservation.clearance)
                #expect(area.isClear(window) == (plan == nil), "\(window)")
            }
        }
    }

    @Test func `clearing moves a window out from under every panel it covers, keeping its size`() {
        let rightPanel = Reservation(
            frame: CGRect(x: 700, y: 20, width: 300, height: 780), edge: .right, role: .main)
        let area = WorkArea(visibleFrame: visible, reservations: [leftPanel, rightPanel], padding: 8)
        let clear = CGRect(x: 400, y: 100, width: 200, height: 300)
        #expect(area.clearing(clear) == nil)
        // Too wide for the room between the two: out from under the left panel, overflowing into the right one's
        // space, which is as good as it gets at a size the app insists on.
        let wide = CGRect(x: 0, y: 100, width: 800, height: 300)
        let moved = area.clearing(wide)
        #expect(moved?.width == 800)
        #expect(moved?.minX != wide.minX)
    }

    @Test func `a safe origin holds the size clear of the panels, or says there's no room`() {
        let area = WorkArea(visibleFrame: visible, reservations: [leftPanel], padding: 8)
        let origin = area.safeOrigin(for: CGSize(width: 400, height: 300))
        #expect(origin == CGPoint(x: 308, y: 20))
        #expect(area.isClear(CGRect(origin: origin ?? .zero, size: CGSize(width: 400, height: 300))))
        #expect(area.safeOrigin(for: CGSize(width: 900, height: 300)) == nil)
    }
}
