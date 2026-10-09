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
