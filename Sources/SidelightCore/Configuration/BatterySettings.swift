import Foundation

/// A battery widget's look. Each style shows the same charge its own way.
public enum BatteryStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The battery glyph with the percentage beside it, like the menu bar.
    case glyph
    /// A gauge ring around the percentage.
    case ring
    /// A large battery cell filled to the charge.
    case cell
    /// Dot-matrix digits over a cell of segments, like an old LCD.
    case pixel

    public var id: Self { self }
}

/// Options that mean the same in every style sit at the top; options only one style has sit in that style's own
/// struct, side by side, so switching styles and back loses nothing.
public struct BatterySettings: Codable, Hashable, Sendable {
    public var style: BatteryStyle = .ring
    /// How long until empty, or until full while charging, as macOS estimates it.
    public var showsTimeRemaining = true
    /// Watts going into or out of the battery, read from the battery's controller.
    public var showsPower = false
    public var glyph = GlyphBatteryOptions()
    public var ring = RingBatteryOptions()
    public var cell = CellBatteryOptions()
    public var pixel = PixelBatteryOptions()

    public init(style: BatteryStyle = .ring, showsTimeRemaining: Bool = true, showsPower: Bool = false) {
        self.style = style
        self.showsTimeRemaining = showsTimeRemaining
        self.showsPower = showsPower
    }

    /// Missing options take their defaults, as does one that can't be read, such as a style only a newer version
    /// offers.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BatterySettings()
        style = container.decodeLeniently(.style, or: defaults.style)
        showsTimeRemaining = container.decodeLeniently(.showsTimeRemaining, or: defaults.showsTimeRemaining)
        showsPower = container.decodeLeniently(.showsPower, or: defaults.showsPower)
        glyph = container.decodeLeniently(.glyph, or: defaults.glyph)
        ring = container.decodeLeniently(.ring, or: defaults.ring)
        cell = container.decodeLeniently(.cell, or: defaults.cell)
        pixel = container.decodeLeniently(.pixel, or: defaults.pixel)
    }
}

public struct GlyphBatteryOptions: Codable, Hashable, Sendable {
    /// The percentage beside the glyph; off leaves the glyph alone, as the menu bar can.
    public var showsPercent = true

    public init(showsPercent: Bool = true) {
        self.showsPercent = showsPercent
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsPercent = container.decodeLeniently(.showsPercent, or: GlyphBatteryOptions().showsPercent)
    }
}

public struct RingBatteryOptions: Codable, Hashable, Sendable {
    public enum Gauge: String, Codable, CaseIterable, Identifiable, Sendable {
        /// One continuous arc.
        case solid
        /// Fine ticks, like the usage widgets' gauges.
        case ticks

        public var id: Self { self }
    }

    public var gauge: Gauge = .solid

    public init(gauge: Gauge = .solid) {
        self.gauge = gauge
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gauge = container.decodeLeniently(.gauge, or: RingBatteryOptions().gauge)
    }
}

public struct CellBatteryOptions: Codable, Hashable, Sendable {
    public enum Finish: String, Codable, CaseIterable, Identifiable, Sendable {
        /// A glossy cell with a highlight, like a classic Aqua control.
        case glass
        /// A plain fill.
        case flat

        public var id: Self { self }
    }

    public var finish: Finish = .glass

    public init(finish: Finish = .glass) {
        self.finish = finish
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        finish = container.decodeLeniently(.finish, or: CellBatteryOptions().finish)
    }
}

public struct PixelBatteryOptions: Codable, Hashable, Sendable {
    /// The color of lit dots. Charging, a low battery and Low Power Mode light them in their own color instead.
    public var color: ClockColor = .green
    /// Unlit dots faintly visible, like an LCD.
    public var showsUnlitPixels = true
    /// A soft halo around lit dots, like an LED or CRT.
    public var glows = true

    public init(color: ClockColor = .green, showsUnlitPixels: Bool = true, glows: Bool = true) {
        self.color = color
        self.showsUnlitPixels = showsUnlitPixels
        self.glows = glows
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PixelBatteryOptions()
        color = container.decodeLeniently(.color, or: defaults.color)
        showsUnlitPixels = container.decodeLeniently(.showsUnlitPixels, or: defaults.showsUnlitPixels)
        glows = container.decodeLeniently(.glows, or: defaults.glows)
    }
}

/// What the battery service has to do for the battery widgets on screen. It runs while one shows (see
/// ``ServiceDemand/kinds``); this says what else to read.
public struct BatteryDemand: Equatable, Sendable {
    /// A widget shows watts, which come from the battery's controller rather than the power-source API.
    public var readsPower = false

    public init(readsPower: Bool = false) {
        self.readsPower = readsPower
    }

    public init(widgets: some Sequence<WidgetInstance>) {
        readsPower = widgets.contains { widget in
            if case .battery(let settings) = widget.settings { settings.showsPower } else { false }
        }
    }
}
