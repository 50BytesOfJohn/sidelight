import Foundation
import Testing

@testable import SidelightCore

struct PanelWidthTests {
    @Test func `presets grow with the screen between the small and large screen widths`() {
        #expect(WidgetDensity.regular.presetWidth(screenWidth: 1280) == 272)
        #expect(WidgetDensity.regular.presetWidth(screenWidth: 2000) == 288)
        #expect(WidgetDensity.regular.presetWidth(screenWidth: 3440) == 304)
        #expect(
            WidgetDensity.compact.presetWidth(screenWidth: 1512) < WidgetDensity.regular.presetWidth(screenWidth: 1512))
    }

    @Test func `custom widths are capped at half the screen`() {
        #expect(PanelWidth.points(900).points(screenWidth: 1512) == 756)
        #expect(PanelWidth.percent(80).points(screenWidth: 2000) == 1000)
        #expect(PanelWidth.percent(25).points(screenWidth: 2000) == 500)
    }

    @Test func `no panel is narrower than the minimal preset`() {
        #expect(PanelWidth.points(10).points(screenWidth: 1512) == PanelWidth.minimumPoints)
        #expect(PanelWidth.percent(1).points(screenWidth: 1512) == PanelWidth.minimumPoints)
    }

    @Test(
        arguments: [
            (.preset(.compact), #""compact""#),
            (.points(420), "420"),
            (.points(420.5), "420.5"),
            (.percent(30), #""30%""#),
            (.percent(27.5), #""27.5%""#),
        ] as [(PanelWidth, String)])
    func `round-trips through its compact JSON form`(width: PanelWidth, json: String) throws {
        #expect(String(decoding: try JSONEncoder().encode(width), as: UTF8.self) == json)
        #expect(try JSONDecoder().decode(PanelWidth.self, from: Data(json.utf8)) == width)
    }

    @Test(arguments: [#""huge""#, #""%""#, #""30 %x""#, "true"])
    func `rejects anything else`(json: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PanelWidth.self, from: Data(json.utf8)) }
    }
}

struct PanelColumnsTests {
    @Test(arguments: WidgetDensity.allCases)
    func `every preset is a single column at its own density`(density: WidgetDensity) {
        for screenWidth in [1280.0, 1512, 1920, 2560, 3440] {
            let columns = PanelColumns(panelWidth: PanelWidth.preset(density).points(screenWidth: screenWidth))
            #expect(columns == PanelColumns(count: 1, density: density))
        }
    }

    @Test(
        arguments: [
            (400.0, PanelColumns(count: 1, density: .regular)),
            (460, PanelColumns(count: 2, density: .compact)),
            (600, PanelColumns(count: 2, density: .regular)),
            (840, PanelColumns(count: 2, density: .regular)),
            (900, PanelColumns(count: 3, density: .regular)),
            (1280, PanelColumns(count: 4, density: .regular)),
        ] as [(Double, PanelColumns)])
    func `wide panels add columns instead of stretching widgets`(width: Double, expected: PanelColumns) {
        #expect(PanelColumns(panelWidth: width) == expected)
    }
}
