import Foundation

/// How densely widgets are drawn in one side-panel column.
public enum WidgetDensity: String, Codable, CaseIterable, Identifiable, Sendable {
    case minimal, compact, regular

    public var id: Self { self }

    /// Screen widths between which presets grow from their small to their large width.
    static let presetScreenWidths: ClosedRange<Double> = 1440...2560

    /// Width of the preset with this density: a single column, a little wider on bigger screens.
    public func presetWidth(screenWidth: Double) -> Double {
        let (small, large): (Double, Double) =
            switch self {
            case .minimal: (64, 72)
            case .compact: (168, 196)
            case .regular: (272, 304)
            }
        let screens = Self.presetScreenWidths
        let progress = min(max((screenWidth - screens.lowerBound) / (screens.upperBound - screens.lowerBound), 0), 1)
        return (small + (large - small) * progress).rounded()
    }
}

/// The side panel's width on one display.
///
/// Stored in `config.json` as a preset name (`"compact"`), a number of points (`420`) or a share of the
/// screen width (`"30%"`).
public enum PanelWidth: Hashable, Sendable {
    /// A single column at the given density, sized for the screen.
    case preset(WidgetDensity)
    /// A fixed width, in points.
    case points(Double)
    /// A share of the screen's width, in percent.
    case percent(Double)

    /// No panel is narrower than the minimal preset.
    public static let minimumPoints: Double = 64
    /// No panel takes more than half the screen.
    public static let maximumScreenFraction: Double = 0.5
    /// What the percent editor offers.
    public static let percentRange: ClosedRange<Double> = 5...50

    /// Widths a panel can have on a screen this wide.
    public static func pointsRange(screenWidth: Double) -> ClosedRange<Double> {
        minimumPoints...max(minimumPoints, (screenWidth * maximumScreenFraction).rounded(.down))
    }

    /// The width in points on a screen this wide, kept within ``pointsRange(screenWidth:)``.
    public func points(screenWidth: Double) -> Double {
        let requested =
            switch self {
            case .preset(let density): density.presetWidth(screenWidth: screenWidth)
            case .points(let points): points
            case .percent(let percent): screenWidth * percent / 100
            }
        let range = Self.pointsRange(screenWidth: screenWidth)
        return min(max(requested, range.lowerBound), range.upperBound).rounded()
    }

    public var preset: WidgetDensity? {
        if case .preset(let density) = self { density } else { nil }
    }
}

extension PanelWidth: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let points = try? container.decode(Double.self) {
            self = .points(points)
            return
        }
        let string = try container.decode(String.self)
        if let density = WidgetDensity(rawValue: string) {
            self = .preset(density)
        } else if string.hasSuffix("%"), let percent = Double(string.dropLast()) {
            self = .percent(percent)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected minimal, compact, regular, a number of points or a percentage like \"30%\""
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .preset(let density): try container.encode(density.rawValue)
        case .points(let points): try container.encode(points)
        case .percent(let percent):
            let number = percent == percent.rounded() ? String(Int(percent)) : String(percent)
            try container.encode(number + "%")
        }
    }
}

/// How a side panel of a given width arranges its widgets: as many columns as it takes to keep each one
/// from getting wider than ``maximumColumnWidth``, at the richest density that column width fits.
public struct PanelColumns: Hashable, Sendable {
    public static let maximumColumnWidth: Double = 420
    /// The narrowest share of the panel a column needs for each density.
    static let regularMinimumWidth: Double = 260
    static let compactMinimumWidth: Double = 120

    public var count: Int
    public var density: WidgetDensity

    public init(count: Int, density: WidgetDensity) {
        self.count = count
        self.density = density
    }

    public init(panelWidth: Double) {
        count = max(1, Int((panelWidth / Self.maximumColumnWidth).rounded(.up)))
        let columnWidth = panelWidth / Double(count)
        density =
            if columnWidth >= Self.regularMinimumWidth {
                .regular
            } else if columnWidth >= Self.compactMinimumWidth {
                .compact
            } else {
                .minimal
            }
    }
}
