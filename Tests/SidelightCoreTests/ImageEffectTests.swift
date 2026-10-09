import CoreGraphics
import Foundation
import Testing

@testable import SidelightCore

struct ImageEffectTests {
    @Test(arguments: ImageEffectKind.allCases)
    func `effect settings round-trip through JSON`(kind: ImageEffectKind) throws {
        var configuration = AppConfiguration()
        configuration.appearance.background.image.effect = ImageEffect(
            kind: kind, size: 7.5, levels: 3, shadows: RGBAColor(hex: "#102030")!,
            highlights: RGBAColor(hex: "#F0E0D0")!)

        let decoded = try AppConfiguration(json: configuration.json())
        #expect(decoded.appearance.background.image.effect == configuration.appearance.background.image.effect)
    }

    @Test func `effects are stored by name with hex colors`() throws {
        let effect = ImageEffect(kind: .halftone, shadows: .black, highlights: RGBAColor(hex: "#FF8800")!)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(effect)) as? [String: Any])
        #expect(json["kind"] as? String == "halftone")
        #expect(json["highlights"] as? String == "#FF8800")
    }

    @Test func `each kind lists the parameters it uses`() {
        #expect(ImageEffectKind.allCases.filter(\.usesSize) == [.dither, .halftone, .pixelate, .ascii])
        #expect(ImageEffectKind.allCases.filter(\.usesLevels) == [.posterize])
        #expect(ImageEffectKind.allCases.filter(\.usesColors) == [.dither, .halftone, .duotone, .ascii])
    }

    @Test func `two-color effects move automatic text towards their colors`() {
        var appearance = Appearance()
        appearance.cards.style = .none
        appearance.background.kind = .image
        appearance.background.image.dim = 0
        appearance.background.image.effect = ImageEffect(kind: .duotone, shadows: .white, highlights: .white)
        // A dark picture turned all white needs dark text.
        #expect(appearance.resolvedText(imageLuminance: 0.02) == .dark)

        appearance.background.image.effect.kind = .pixelate
        #expect(appearance.resolvedText(imageLuminance: 0.02) == .light)
    }
}

struct ImageEffectPatternsTests {
    @Test func `the Bayer matrix holds every threshold once`() {
        let values = ImageEffectPatterns.bayer.flatMap(\.self)
        #expect(ImageEffectPatterns.bayer.count == 8)
        #expect(ImageEffectPatterns.bayer.allSatisfy { $0.count == 8 })
        #expect(values.sorted() == Array(0..<64))
        #expect(ImageEffectPatterns.bayer[0][0...1] == [0, 32])
    }

    @Test func `ordered dithering lights a share of cells equal to the brightness`() {
        func lit(_ brightness: Double) -> Int {
            (0..<8).flatMap { y in (0..<8).map { x in (x, y) } }
                .filter { ImageEffectPatterns.isLight(brightness: brightness, x: $0.0, y: $0.1) }.count
        }
        #expect(lit(0) == 0)
        #expect(lit(1) == 64)
        #expect(lit(0.5) == 32)
        #expect(lit(0.25) == 16)
        // The pattern repeats every 8 cells.
        #expect(
            ImageEffectPatterns.isLight(brightness: 0.3, x: 3, y: 5)
                == ImageEffectPatterns.isLight(brightness: 0.3, x: 11, y: 13))
    }

    @Test func `brightness is stretched to the full range`() {
        #expect(ImageEffectPatterns.stretched([0.25, 0.5, 0.75]) == [0, 0.5, 1])
        // A flat picture stays as it is instead of turning into noise.
        #expect(ImageEffectPatterns.stretched([0.5, 0.5]) == [0.5, 0.5])
        #expect(ImageEffectPatterns.stretched([]) == [])
    }

    @Test func `ASCII art runs from blank to dense`() {
        #expect(ImageEffectPatterns.asciiCharacter(brightness: 0) == " ")
        #expect(ImageEffectPatterns.asciiCharacter(brightness: 1) == "@")
        #expect(ImageEffectPatterns.asciiCharacter(brightness: -3) == " ")
        #expect(ImageEffectPatterns.asciiCharacter(brightness: 0.5) == "+")
    }
}

struct WallpaperGeometryTests {
    /// A 3000 × 1500 screen whose origin isn't zero, as on a secondary display.
    static let screen = CGRect(x: 1000, y: -200, width: 3000, height: 1500)

    @Test func `a picture with the screen's aspect maps linearly`() {
        let left = CGRect(x: 1000, y: -200, width: 300, height: 1500)
        #expect(crop(left, image: CGSize(width: 6000, height: 3000)) == CGRect(x: 0, y: 0, width: 600, height: 3000))
    }

    @Test func `the top of the screen is the top of the picture`() {
        let topBar = CGRect(x: 1000, y: 1256, width: 3000, height: 44)
        #expect(crop(topBar, image: CGSize(width: 3000, height: 1500)) == CGRect(x: 0, y: 0, width: 3000, height: 44))
        let bottomBar = CGRect(x: 1000, y: -200, width: 3000, height: 44)
        #expect(crop(bottomBar, image: CGSize(width: 3000, height: 1500)).minY == 1456)
    }

    @Test func `a taller picture is centered and its overflow cut off`() {
        // 3000 × 3000 covers the screen at scale 1, with 750 px above and below.
        let right = CGRect(x: 3700, y: -200, width: 300, height: 1500)
        #expect(
            crop(right, image: CGSize(width: 3000, height: 3000)) == CGRect(x: 2700, y: 750, width: 300, height: 1500))
    }

    @Test func `a wider picture is centered and scaled to the screen's height`() {
        // 8000 × 2000 covers the screen at scale 4/3, 4000 wide, with 2000 px left and right.
        let left = CGRect(x: 1000, y: -200, width: 300, height: 1500)
        let crop = crop(left, image: CGSize(width: 8000, height: 2000))
        #expect(crop.minX == 2000)
        #expect(crop.width == 400)
        #expect(crop.height == 2000)
    }

    private func crop(_ rect: CGRect, image: CGSize) -> CGRect {
        WallpaperGeometry.crop(of: rect, onScreen: Self.screen, imageSize: image)
    }
}
