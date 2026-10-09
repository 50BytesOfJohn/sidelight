import Foundation
import SidelightCore

// User-facing names for configuration values.

extension PanelPosition {
    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .left: "rectangle.lefthalf.inset.filled"
        case .right: "rectangle.righthalf.inset.filled"
        case .top: "rectangle.tophalf.inset.filled"
        case .bottom: "rectangle.bottomhalf.inset.filled"
        }
    }
}

extension PanelLength {
    var title: String {
        switch self {
        case .fill: "Fill edge"
        case .fit: "Fit content"
        }
    }
}

extension PanelAlignment {
    /// Top, Middle and Bottom along a side panel's edge; Left, Center and Right along a bar's.
    func title(for position: PanelPosition) -> String {
        switch (self, position.isBar) {
        case (.start, false): "Top"
        case (.center, false): "Middle"
        case (.end, false): "Bottom"
        case (.start, true): "Left"
        case (.center, true): "Center"
        case (.end, true): "Right"
        }
    }
}

extension WidgetDensity {
    var title: String { rawValue.capitalized }
}

extension PanelWidth {
    /// e.g. `Compact` or `Custom (30 %)`.
    var title: String {
        switch self {
        case .preset(let density): density.title
        case .points(let points): "Custom (\(Int(points)) pt)"
        case .percent(let percent): "Custom (\(percent.formatted(.number.precision(.fractionLength(0...1)))) %)"
        }
    }
}

extension PanelColumns {
    /// e.g. `2 columns · regular widgets`.
    var summary: String {
        (count == 1 ? "1 column" : "\(count) columns") + " · \(density.rawValue) widgets"
    }
}

extension BackgroundKind {
    var title: String {
        switch self {
        case .none: "None"
        case .glass: "Glass"
        case .blur: "Blur"
        case .color: "Color"
        case .image: "Image"
        }
    }

    var explanation: String {
        switch self {
        case .none: "No background: the desktop and windows show through. Pair with glass or blur cards."
        case .glass: "Liquid Glass, refracting whatever is behind the panel."
        case .blur: "A frosted blur of whatever is behind the panel, with an adjustable radius."
        case .color: "A solid color or gradient, optionally translucent."
        case .image: "Your desktop picture or an image of your choice."
        }
    }
}

extension GlassVariant {
    var title: String { rawValue.capitalized }
}

extension BlurMaterial {
    var title: String { rawValue.capitalized }
}

extension ColorFill {
    var title: String { rawValue.capitalized }
}

extension ImageEffectKind {
    var title: String {
        switch self {
        case .none: "None"
        case .dither: "Dither"
        case .halftone: "Halftone"
        case .pixelate: "Pixelate"
        case .posterize: "Posterize"
        case .duotone: "Duotone"
        case .ascii: "ASCII"
        }
    }
}

extension CardStyle {
    var title: String { rawValue.capitalized }
}

extension TextAppearance {
    var title: String { rawValue.capitalized }
}

extension WindowAvoidanceMode {
    var title: String { rawValue.capitalized }

    var explanation: String {
        switch self {
        case .off: "Windows are never moved."
        case .shift: "Overlapping windows are moved away from the panel, keeping their size."
        case .clip: "Overlapping windows keep their far edge and shrink by the overlap."
        case .smart: "Clip windows snapped or maximized against the edge, shift free-floating ones."
        }
    }
}
