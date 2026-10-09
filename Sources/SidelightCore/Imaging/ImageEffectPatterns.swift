import Foundation

/// The pixel math behind the effects Core Image doesn't have.
public enum ImageEffectPatterns {
    /// The 8×8 Bayer matrix: every threshold level from 0 to 63 once, spread so neighbours differ the most.
    public static let bayer: [[Int]] = {
        var matrix = [[0]]
        while matrix.count < 8 {
            let size = matrix.count
            matrix = (0..<size * 2).map { y in
                (0..<size * 2).map { x in
                    let quadrant = [[0, 2], [3, 1]][y / size][x / size]
                    return 4 * matrix[y % size][x % size] + quadrant
                }
            }
        }
        return matrix
    }()

    /// Whether ordered dithering draws the cell at (`x`, `y`) in the light color, for a cell of `brightness` 0...1.
    public static func isLight(brightness: Double, x: Int, y: Int) -> Bool {
        brightness > (Double(bayer[y & 7][x & 7]) + 0.5) / 64
    }

    /// Characters from empty to dense; brighter cells get denser ones.
    public static let asciiRamp = Array(" .:-=+*#%@")

    public static func asciiCharacter(brightness: Double) -> Character {
        let index = Int((min(max(brightness, 0), 1) * Double(asciiRamp.count - 1)).rounded())
        return asciiRamp[index]
    }

    /// `values` with their range stretched to 0...1, so a dark or flat picture still uses every dither level and
    /// every ASCII character. The darkest and brightest 2 % are clipped, so a few stray pixels don't decide the range.
    public static func stretched(_ values: [Double]) -> [Double] {
        guard !values.isEmpty else { return values }
        let sorted = values.sorted()
        let low = sorted[Int((Double(sorted.count - 1) * 0.02).rounded())]
        let high = sorted[Int((Double(sorted.count - 1) * 0.98).rounded())]
        guard high - low > 0.01 else { return values }
        return values.map { min(max(($0 - low) / (high - low), 0), 1) }
    }

    /// Perceived brightness of gamma-encoded sRGB components (0...1), as dithering and ASCII art should see it.
    public static func brightness(red: Double, green: Double, blue: Double) -> Double {
        0.299 * red + 0.587 * green + 0.114 * blue
    }
}
