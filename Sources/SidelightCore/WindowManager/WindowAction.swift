import CoreGraphics

/// What a window manager shortcut does to the frontmost window. The raw values are the keys `config.json` saves
/// shortcuts under, and follow Rectangle's names, so its settings would map one to one.
public enum WindowAction: String, CaseIterable, Codable, CodingKeyRepresentable, Identifiable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird
    case firstTwoThirds, centerTwoThirds, lastTwoThirds
    case maximize, center, restore
    case nextDisplay, previousDisplay

    public var id: Self { self }

    /// Halves: pressed again soon on the same window, they go ½ → ⅓ → ⅔ → ½ (see ``SizeCycle``).
    public var cycles: Bool {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: true
        default: false
        }
    }

    /// How many sizes pressing it again steps through.
    var cycleLength: Int { cycles ? 3 : 1 }

    /// Whether it puts the window somewhere on its display (a tile, maximized or centred), rather than putting it
    /// back or sending it to another display.
    public var isPlacement: Bool {
        switch self {
        case .restore, .nextDisplay, .previousDisplay: false
        default: true
        }
    }

    /// The part of the work area the window takes at `step` of its cycle, with x and y fractions growing right and
    /// down; `nil` for actions that aren't a tile (center, restore, the displays). Thirds run along the display's long
    /// side: top to bottom on a portrait display.
    public func unitRect(step: Int = 0, isPortrait: Bool = false) -> UnitRect? {
        // The size a half is at this step: ½, then ⅓, then ⅔.
        let share: Double = [1 / 2, 1 / 3, 2 / 3][cycles ? step % cycleLength : 0]
        let third = 1.0 / 3
        let twoThirds = 2.0 / 3
        func along(_ start: Double, _ end: Double) -> UnitRect {
            isPortrait
                ? UnitRect(minX: 0, minY: start, maxX: 1, maxY: end)
                : UnitRect(minX: start, minY: 0, maxX: end, maxY: 1)
        }
        switch self {
        case .leftHalf: return UnitRect(minX: 0, minY: 0, maxX: share, maxY: 1)
        case .rightHalf: return UnitRect(minX: 1 - share, minY: 0, maxX: 1, maxY: 1)
        case .topHalf: return UnitRect(minX: 0, minY: 0, maxX: 1, maxY: share)
        case .bottomHalf: return UnitRect(minX: 0, minY: 1 - share, maxX: 1, maxY: 1)
        case .topLeft: return UnitRect(minX: 0, minY: 0, maxX: 0.5, maxY: 0.5)
        case .topRight: return UnitRect(minX: 0.5, minY: 0, maxX: 1, maxY: 0.5)
        case .bottomLeft: return UnitRect(minX: 0, minY: 0.5, maxX: 0.5, maxY: 1)
        case .bottomRight: return UnitRect(minX: 0.5, minY: 0.5, maxX: 1, maxY: 1)
        case .firstThird: return along(0, third)
        case .centerThird: return along(third, twoThirds)
        case .lastThird: return along(twoThirds, 1)
        case .firstTwoThirds: return along(0, twoThirds)
        case .centerTwoThirds: return along(1.0 / 6, 5.0 / 6)
        case .lastTwoThirds: return along(third, 1)
        case .maximize: return UnitRect(minX: 0, minY: 0, maxX: 1, maxY: 1)
        case .center, .restore, .nextDisplay, .previousDisplay: return nil
        }
    }
}

/// A rect in fractions of a work area, by its edges, so two tiles that share an edge share its exact value.
public struct UnitRect: Equatable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }
}
