import Foundation

/// A stylized look for the background image, rendered once into the bitmap.
public enum ImageEffectKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    /// Retro 1-bit ordered (Bayer) dithering in two colors.
    case dither
    /// Newspaper-style dots in two colors.
    case halftone
    /// Big square pixels.
    case pixelate
    /// A few flat levels per color channel.
    case posterize
    /// Brightness mapped onto a gradient between two colors.
    case duotone
    /// Brightness drawn as monospaced characters.
    case ascii

    public var id: Self { self }

    /// Whether ``ImageEffect/size`` applies.
    public var usesSize: Bool { self == .dither || self == .halftone || self == .pixelate || self == .ascii }
    /// Whether ``ImageEffect/levels`` applies.
    public var usesLevels: Bool { self == .posterize }
    /// Whether ``ImageEffect/shadows`` and ``ImageEffect/highlights`` apply.
    public var usesColors: Bool { self == .dither || self == .halftone || self == .duotone || self == .ascii }
}

/// One effect with a few shared parameters, so the settings stay one short section.
public struct ImageEffect: Codable, Hashable, Sendable {
    /// What the settings offer.
    public static let sizeRange: ClosedRange<Double> = 2...24
    public static let levelsRange: ClosedRange<Int> = 2...8

    public var kind: ImageEffectKind = .none
    /// Cell, dot or pixel size in points.
    public var size: Double = 4
    /// Levels per color channel, for posterize.
    public var levels = 4
    /// Two-color effects map dark to `shadows` and light to `highlights`.
    public var shadows: RGBAColor = .black
    public var highlights: RGBAColor = .white

    public init(
        kind: ImageEffectKind = .none,
        size: Double = 4,
        levels: Int = 4,
        shadows: RGBAColor = .black,
        highlights: RGBAColor = .white
    ) {
        self.kind = kind
        self.size = size
        self.levels = levels
        self.shadows = shadows
        self.highlights = highlights
    }

    /// Roughly how bright an image of average `luminance` is after the effect, for picking the text color.
    public func luminance(afterApplyingTo luminance: Double) -> Double {
        guard kind.usesColors else { return luminance }
        return shadows.luminance + (highlights.luminance - shadows.luminance) * luminance
    }
}
