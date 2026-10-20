import CoreGraphics
import Testing

@testable import SidelightCore

struct PanelGeometryTests {
    /// A left strip 300 pt wide and 1000 pt tall, and a bottom strip 2000 pt wide and 44 pt tall.
    static let sideStrip = CGRect(x: 0, y: 25, width: 300, height: 1000)
    static let barStrip = CGRect(x: 100, y: 0, width: 2000, height: 44)

    @Test(arguments: PanelAlignment.allCases)
    func `filling panels take the whole strip`(alignment: PanelAlignment) {
        #expect(frame(Self.sideStrip, .left, .fill, alignment, content: 200) == Self.sideStrip)
        #expect(frame(Self.barStrip, .bottom, .fill, alignment, content: 200) == Self.barStrip)
    }

    @Test(
        arguments: [
            (.start, CGRect(x: 0, y: 625, width: 300, height: 400)),
            (.center, CGRect(x: 0, y: 325, width: 300, height: 400)),
            (.end, CGRect(x: 0, y: 25, width: 300, height: 400)),
        ] as [(PanelAlignment, CGRect)])
    func `fitted side panels start at the top`(alignment: PanelAlignment, expected: CGRect) {
        #expect(frame(Self.sideStrip, .left, .fit, alignment, content: 400) == expected)
    }

    @Test(
        arguments: [
            (.start, CGRect(x: 100, y: 0, width: 500, height: 44)),
            (.center, CGRect(x: 850, y: 0, width: 500, height: 44)),
            (.end, CGRect(x: 1600, y: 0, width: 500, height: 44)),
        ] as [(PanelAlignment, CGRect)])
    func `fitted bars start at the left`(alignment: PanelAlignment, expected: CGRect) {
        #expect(frame(Self.barStrip, .bottom, .fit, alignment, content: 500) == expected)
    }

    @Test func `fitted panels stay between the minimum length and the strip`() {
        #expect(frame(Self.sideStrip, .right, .fit, .start, content: 0).height == PanelGeometry.minimumLength)
        #expect(frame(Self.sideStrip, .right, .fit, .center, content: 5000) == Self.sideStrip)
        #expect(frame(Self.barStrip, .top, .fit, .end, content: 5000) == Self.barStrip)
    }

    @Test func `fitted lengths and centered origins are whole points`() {
        let fitted = frame(Self.sideStrip, .left, .fit, .center, content: 400.3)
        #expect(fitted.height == 401)
        #expect(fitted.minY == fitted.minY.rounded())
    }

    private func frame(
        _ strip: CGRect, _ position: PanelPosition, _ length: PanelLength, _ alignment: PanelAlignment,
        content: CGFloat
    ) -> CGRect {
        PanelGeometry.frame(
            inStrip: strip, position: position, length: length, alignment: alignment, contentLength: content)
    }
}

struct NotchOutlineTests {
    static let rect = CGRect(x: 10, y: 20, width: 200, height: 100)

    @Test(arguments: PanelPosition.allCases)
    func `fills its rect`(edge: PanelPosition) {
        let path = NotchOutline.path(in: Self.rect, edge: edge, cornerRadius: 20, shoulder: 10)
        #expect(path.boundingBoxOfPath.isClose(to: Self.rect))
        #expect(path.contains(CGPoint(x: Self.rect.midX, y: Self.rect.midY)))
    }

    @Test func `shoulders flare into the edge and the far corners are rounded`() {
        // Joined to the top: the shoulders fill the edge's corners, not the space below them.
        let top = NotchOutline.path(in: Self.rect, edge: .top, cornerRadius: 20, shoulder: 10)
        #expect(top.contains(CGPoint(x: 19, y: 21)))
        #expect(!top.contains(CGPoint(x: 11, y: 29)))
        #expect(!top.contains(CGPoint(x: 209, y: 119)))
        // Joined to the left, the shoulders reach along it, up and down.
        let left = NotchOutline.path(in: Self.rect, edge: .left, cornerRadius: 20, shoulder: 10)
        #expect(left.contains(CGPoint(x: 11, y: 29)))
        #expect(!left.contains(CGPoint(x: 19, y: 21)))
        #expect(!left.contains(CGPoint(x: 209, y: 119)))
    }

    @Test func `an open outline leaves the edge out`() {
        let open = NotchOutline.path(in: Self.rect, edge: .bottom, cornerRadius: 20, shoulder: 10, isClosed: false)
        #expect(abs(open.currentPoint.x - Self.rect.maxX) < 0.001)
        #expect(abs(open.currentPoint.y - Self.rect.maxY) < 0.001)
    }

    @Test func `oversized radii stay inside a small rect`() {
        let small = CGRect(x: 0, y: 0, width: 30, height: 12)
        let path = NotchOutline.path(in: small, edge: .top, cornerRadius: 100, shoulder: 100)
        #expect(path.boundingBoxOfPath.isClose(to: small))
    }
}

extension CGRect {
    fileprivate func isClose(to other: CGRect) -> Bool {
        [minX - other.minX, minY - other.minY, maxX - other.maxX, maxY - other.maxY].allSatisfy { abs($0) < 0.001 }
    }
}
