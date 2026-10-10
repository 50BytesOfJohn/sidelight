import Foundation

/// How the panel and its widget cards look. The same on every display.
public struct Appearance: Codable, Hashable, Sendable {
    public var background = BackgroundSettings()
    public var cards = CardSettings()
    public var text: TextAppearance = .automatic

    public init() {}
}

// MARK: Background

/// What's drawn behind the widgets.
public enum BackgroundKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Nothing: the desktop and windows show through, only the cards are drawn.
    case none
    /// Liquid Glass.
    case glass
    /// The classic blurred material, with an adjustable blur radius.
    case blur
    /// A solid color or gradient.
    case color
    /// A picture, the desktop picture by default.
    case image

    public var id: Self { self }
}

/// The background, with the settings of every kind kept side by side so switching kinds and back loses nothing.
public struct BackgroundSettings: Codable, Hashable, Sendable {
    /// What the settings slider offers.
    public static let grainRange: ClosedRange<Double> = 0...1

    public var kind: BackgroundKind = .glass
    public var glass = GlassBackground()
    public var blur = BlurBackground()
    public var color = ColorBackground()
    public var image = ImageBackground()
    /// Opacity of film-grain noise over blur, color and image backgrounds.
    public var grain: Double = 0

    public init() {}

    /// Whether ``grain`` applies to the current kind.
    public var showsGrain: Bool { kind == .blur || kind == .color || kind == .image }
}

public enum GlassVariant: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Frosted enough to keep text readable over anything.
    case regular
    /// More transparent; best over dark or quiet backgrounds.
    case clear

    public var id: Self { self }
}

public struct GlassBackground: Codable, Hashable, Sendable {
    public var variant: GlassVariant = .regular
    public var tint = Tint(color: .black, amount: 0)

    public init() {}
}

/// How much of what's behind shows through the blur. All but ``dark`` follow the system's light or dark mode.
public enum BlurMaterial: String, Codable, CaseIterable, Identifiable, Sendable {
    case thin, regular, thick
    /// Dark in light mode too.
    case dark

    public var id: Self { self }
}

public struct BlurBackground: Codable, Hashable, Sendable {
    /// What the settings slider offers, in points. macOS's own materials use 30.
    public static let radiusRange: ClosedRange<Double> = 0...80

    public var material: BlurMaterial = .regular
    public var radius: Double = 30
    public var tint = Tint(color: .black, amount: 0)

    public init() {}
}

public enum ColorFill: String, Codable, CaseIterable, Identifiable, Sendable {
    case solid, gradient

    public var id: Self { self }
}

public struct ColorBackground: Codable, Hashable, Sendable {
    /// How many colors a gradient can have.
    public static let gradientColorCount = 2...4

    public var fill: ColorFill = .gradient
    public var color = RGBAColor(hex: "#1C1C1E")!
    public var gradient: [RGBAColor] = [RGBAColor(hex: "#3A2A7A")!, RGBAColor(hex: "#0E1530")!]
    /// Direction of the gradient in degrees: 0 runs left to right, 90 top to bottom.
    public var angle: Double = 120
    /// Slowly drifts the gradient. Costs CPU while visible.
    public var isAnimated = false
    public var opacity: Double = 1

    public init() {}

    /// The colors actually shown, for ``fill``.
    public var visibleColors: [RGBAColor] { fill == .solid ? [color] : gradient }
}

public struct ImageBackground: Codable, Hashable, Sendable {
    /// What the settings sliders offer.
    public static let dimRange: ClosedRange<Double> = 0...0.85
    public static let fadeRange: ClosedRange<Double> = 0...1
    /// Blur radius as a fraction of the image's shorter side.
    public static let blurRange: ClosedRange<Double> = 0...0.1

    /// Absolute path of the image; `nil` uses the current desktop picture.
    public var path: String?
    public var tint = Tint(color: .black, amount: 0)
    public var blur: Double = 0
    /// Black overlay opacity on top of the image.
    public var dim: Double = 0.3
    /// Opacity of the fade-to-black gradient at the bottom of the image.
    public var fade: Double = 0.6
    /// Applied after cropping and blurring, under the tint, dim and fade.
    public var effect = ImageEffect()

    public init() {}
}

// MARK: Cards

/// How each widget's card is drawn.
public enum CardStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// No card: widgets sit directly on the background.
    case none
    /// A Liquid Glass card.
    case glass
    /// A blurred-material card.
    case blur
    /// A flat color with adjustable opacity.
    case solid

    public var id: Self { self }
}

public struct CardSettings: Codable, Hashable, Sendable {
    public var style: CardStyle = .solid
    /// Tint of glass and blur cards.
    public var tint = Tint(color: .black, amount: 0)
    /// Color and opacity of solid cards.
    public var fill = Tint(color: .white, amount: 0.06)
    /// The widget's icon and name above its content, in regular and compact layouts. Minimal and bar layouts
    /// never show one.
    public var showsTitles = true

    public init() {}

    /// Missing options take their defaults, so settings saved before an option existed still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try container.decode(CardStyle.self, forKey: .style)
        tint = try container.decode(Tint.self, forKey: .tint)
        fill = try container.decode(Tint.self, forKey: .fill)
        showsTitles = try container.decodeIfPresent(Bool.self, forKey: .showsTitles) ?? CardSettings().showsTitles
    }
}

// MARK: Text

/// Whether text and symbols are light or dark.
public enum TextAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Picked to contrast with the background, or follows the system for glass and blur.
    case automatic
    /// Light text, for dark backgrounds.
    case light
    /// Dark text, for light backgrounds.
    case dark

    public var id: Self { self }
}

extension Appearance {
    /// The text that reads best on what's directly behind it: `.automatic` means follow the system appearance,
    /// which glass and blurred materials adapt to.
    ///
    /// - Parameter imageLuminance: Average relative luminance of the background image, if it's known.
    public func resolvedText(imageLuminance: Double?) -> TextAppearance {
        guard text == .automatic else { return text }
        if cards.style == .solid, cards.fill.amount >= 0.6 {
            return Self.text(on: cards.fill.color.luminance)
        }
        switch background.kind {
        case .none:
            return .automatic
        case .glass:
            return Self.text(on: background.glass.tint)
        case .blur:
            let blur = background.blur
            if blur.tint.amount < 0.5, blur.material == .dark { return .light }
            return Self.text(on: blur.tint)
        case .color:
            let color = background.color
            guard color.opacity >= 0.4 else { return .automatic }
            let colors = color.visibleColors
            return Self.text(on: colors.map(\.luminance).reduce(0, +) / Double(max(1, colors.count)))
        case .image:
            let image = background.image
            guard let imageLuminance else { return .light }
            let effected = image.effect.luminance(afterApplyingTo: imageLuminance)
            let tinted = effected * (1 - image.tint.amount) + image.tint.color.luminance * image.tint.amount
            return Self.text(on: tinted * (1 - image.dim))
        }
    }

    /// A strong tint decides the text; a light one leaves it to the system.
    private static func text(on tint: Tint) -> TextAppearance {
        tint.amount >= 0.5 ? text(on: tint.color.luminance) : .automatic
    }

    private static func text(on luminance: Double) -> TextAppearance {
        // 0.18 is where black and white text have the same contrast ratio.
        luminance > 0.18 ? .dark : .light
    }
}

// MARK: Colors

/// A color and how strongly it's applied: a tint's amount, or a fill's opacity.
public struct Tint: Codable, Hashable, Sendable {
    public var color: RGBAColor
    public var amount: Double

    public init(color: RGBAColor, amount: Double) {
        self.color = color
        self.amount = amount
    }
}

/// An sRGB color, stored in `config.json` as `#RRGGBB` or `#RRGGBBAA` so it's easy to hand-edit.
public struct RGBAColor: Codable, Hashable, Sendable {
    public private(set) var red: Double
    public private(set) var green: Double
    public private(set) var blue: Double
    public private(set) var alpha: Double

    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)

    /// Components are clamped and rounded to 8 bits, the precision `config.json` stores, so a color reads back
    /// from the file exactly as it was.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        func quantized(_ component: Double) -> Double { (min(max(component, 0), 1) * 255).rounded() / 255 }
        self.red = quantized(red)
        self.green = quantized(green)
        self.blue = quantized(blue)
        self.alpha = quantized(alpha)
    }

    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
        let rgba = digits.count == 6 ? value << 8 | 0xFF : value
        self.init(
            red: Double(rgba >> 24 & 0xFF) / 255,
            green: Double(rgba >> 16 & 0xFF) / 255,
            blue: Double(rgba >> 8 & 0xFF) / 255,
            alpha: Double(rgba & 0xFF) / 255
        )
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when the color isn't opaque.
    public var hex: String {
        func byte(_ component: Double) -> String {
            let value = Int((component * 255).rounded())
            return String(value, radix: 16, uppercase: true).leftPadded(to: 2)
        }
        let rgb = "#" + byte(red) + byte(green) + byte(blue)
        return alpha < 1 ? rgb + byte(alpha) : rgb
    }

    /// WCAG relative luminance, ignoring alpha.
    public var luminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let color = RGBAColor(hex: hex) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected a color like #RRGGBB or #RRGGBBAA, got \(hex)")
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

extension String {
    fileprivate func leftPadded(to length: Int) -> String {
        String(repeating: "0", count: max(0, length - count)) + self
    }
}
