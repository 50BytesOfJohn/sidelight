import AppKit
import SidelightCore
import SwiftUI

extension Color {
    init(_ color: RGBAColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }

    /// The tint's color at its amount.
    init(_ tint: Tint) {
        self = Color(tint.color).opacity(tint.amount)
    }
}

extension RGBAColor {
    /// `color` converted to sRGB, or `nil` for colors that have no fixed value (e.g. pattern colors).
    init?(_ color: Color) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent),
            alpha: Double(srgb.alphaComponent)
        )
    }
}

extension Binding where Value == RGBAColor {
    /// For `ColorPicker`, which edits a `Color`.
    var asColor: Binding<Color> {
        Binding<Color> {
            Color(wrappedValue)
        } set: { newValue in
            if let color = RGBAColor(newValue) { wrappedValue = color }
        }
    }
}
