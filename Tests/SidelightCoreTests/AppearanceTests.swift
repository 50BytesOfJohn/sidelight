import Foundation
import Testing

@testable import SidelightCore

struct RGBAColorTests {
    @Test(arguments: [
        ("#1C1C1E", RGBAColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255)),
        ("FFFFFF", RGBAColor.white),
        ("#00000080", RGBAColor(red: 0, green: 0, blue: 0, alpha: 128 / 255)),
    ])
    func `parses hex`(hex: String, expected: RGBAColor) throws {
        let color = try #require(RGBAColor(hex: hex))
        #expect(abs(color.red - expected.red) < 0.001)
        #expect(abs(color.green - expected.green) < 0.001)
        #expect(abs(color.blue - expected.blue) < 0.001)
        #expect(abs(color.alpha - expected.alpha) < 0.001)
    }

    @Test(arguments: ["", "#12345", "#GGGGGG", "#1234567"])
    func `rejects malformed hex`(hex: String) {
        #expect(RGBAColor(hex: hex) == nil)
    }

    @Test func `writes alpha only when translucent`() {
        #expect(RGBAColor.white.hex == "#FFFFFF")
        #expect(RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.5).hex == "#FF000080")
    }

    @Test func `is stored as a hex string`() throws {
        let data = try JSONEncoder().encode(Tint(color: .black, amount: 1))
        #expect(String(decoding: data, as: UTF8.self).contains(##""color":"#000000""##))
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Tint.self, from: Data(#"{"color":"black","amount":1}"#.utf8))
        }
    }
}

struct TextAppearanceTests {
    private func appearance(_ change: (inout Appearance) -> Void) -> Appearance {
        var appearance = Appearance()
        change(&appearance)
        return appearance
    }

    @Test func `an explicit choice wins`() {
        let light = appearance {
            $0.text = .light
            $0.background.kind = .color
            $0.background.color.fill = .solid
            $0.background.color.color = .white
        }
        #expect(light.resolvedText(imageLuminance: nil) == .light)
    }

    @Test func `glass and blur follow the system unless strongly tinted`() {
        #expect(appearance { $0.background.kind = .glass }.resolvedText(imageLuminance: nil) == .automatic)
        let tinted = appearance {
            $0.background.kind = .glass
            $0.background.glass.tint = Tint(color: .white, amount: 0.8)
        }
        #expect(tinted.resolvedText(imageLuminance: nil) == .dark)
        #expect(
            appearance {
                $0.background.kind = .blur
                $0.background.blur.material = .dark
            }
            .resolvedText(imageLuminance: nil) == .light)
    }

    @Test func `contrasts with an opaque color`() {
        let white = appearance {
            $0.background.kind = .color
            $0.background.color.fill = .solid
            $0.background.color.color = .white
        }
        #expect(white.resolvedText(imageLuminance: nil) == .dark)
        var faint = white
        faint.background.color.opacity = 0.2
        #expect(faint.resolvedText(imageLuminance: nil) == .automatic)
    }

    @Test func `accounts for image dimming`() {
        let image = appearance {
            $0.background.kind = .image
            $0.background.image.dim = 0
        }
        #expect(image.resolvedText(imageLuminance: 0.8) == .dark)
        #expect(image.resolvedText(imageLuminance: 0.05) == .light)
        var dimmed = image
        dimmed.background.image.dim = 0.85
        #expect(dimmed.resolvedText(imageLuminance: 0.8) == .light)
        #expect(image.resolvedText(imageLuminance: nil) == .light)
    }

    @Test func `opaque cards decide over the background`() {
        let cards = appearance {
            $0.background.kind = .glass
            $0.cards.style = .solid
            $0.cards.fill = Tint(color: .white, amount: 0.9)
        }
        #expect(cards.resolvedText(imageLuminance: nil) == .dark)
    }
}

struct RGBAColorPrecisionTests {
    @Test func `keeps only the precision the file stores`() throws {
        let color = RGBAColor(red: 0.5, green: 1.2, blue: -1, alpha: 0.333)
        let decoded = try JSONDecoder().decode(RGBAColor.self, from: JSONEncoder().encode(color))
        #expect(decoded == color)
        #expect(color.green == 1 && color.blue == 0)
    }
}
