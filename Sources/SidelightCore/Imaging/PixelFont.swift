import Foundation

/// A dot in a ``PixelLine``, counted from the top-left.
public struct PixelPoint: Hashable, Sendable {
    public let column: Int
    public let row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }
}

/// A line of text laid out in ``PixelFont``: which dots of its grid are lit.
public struct PixelLine: Equatable, Sendable {
    public let columns: Int
    public var rows: Int { PixelFont.height }
    public let lit: [PixelPoint]
    /// The dots of each character cell that stay dark, for displays that show them faintly.
    public let unlit: [PixelPoint]

    public init(_ text: String) {
        var lit: [PixelPoint] = []
        var unlit: [PixelPoint] = []
        var column = 0
        for glyph in PixelFont.glyphs(for: text) {
            if column > 0 { column += PixelFont.spacing }
            for (row, pattern) in glyph.enumerated() {
                for (offset, pixel) in pattern.enumerated() {
                    let point = PixelPoint(column: column + offset, row: row)
                    if pixel == "#" { lit.append(point) } else { unlit.append(point) }
                }
            }
            column += glyph.first?.count ?? 0
        }
        columns = column
        self.lit = lit
        self.unlit = unlit
    }
}

/// A 5×7 bitmap font for retro, dot-matrix text: digits, capital Latin letters and a little punctuation.
public enum PixelFont {
    public static let height = 7
    /// Empty columns between characters.
    public static let spacing = 1

    /// The glyphs for `text`: uppercased and without accents. Characters the font lacks are left blank.
    static func glyphs(for text: String) -> [[String]] {
        var normalized = text.uppercased().folding(options: .diacriticInsensitive, locale: nil)
        for (letter, replacement) in substitutes {
            normalized = normalized.replacingOccurrences(of: letter, with: replacement)
        }
        return normalized.map { glyphs[$0] ?? missing }
    }

    /// Letters that keep their stroke when accents are folded away.
    private static let substitutes = ["Ł": "L", "Ø": "O", "Đ": "D", "Æ": "AE", "Œ": "OE"]

    private static let missing = Array(repeating: ".....", count: height)

    /// Each glyph's rows from top to bottom, `#` for a lit dot. All rows of a glyph are the same width.
    static let glyphs: [Character: [String]] = [
        " ": [
            "...",
            "...",
            "...",
            "...",
            "...",
            "...",
            "...",
        ],
        ":": [
            ".",
            ".",
            "#",
            ".",
            "#",
            ".",
            ".",
        ],
        ".": [
            ".",
            ".",
            ".",
            ".",
            ".",
            ".",
            "#",
        ],
        ",": [
            "..",
            "..",
            "..",
            "..",
            "..",
            ".#",
            "#.",
        ],
        "-": [
            "...",
            "...",
            "...",
            "###",
            "...",
            "...",
            "...",
        ],
        "/": [
            "....#",
            "....#",
            "...#.",
            "..#..",
            ".#...",
            "#....",
            "#....",
        ],
        "0": [
            ".###.",
            "#...#",
            "#...#",
            "#...#",
            "#...#",
            "#...#",
            ".###.",
        ],
        "1": [
            "..#..",
            ".##..",
            "..#..",
            "..#..",
            "..#..",
            "..#..",
            ".###.",
        ],
        "2": [
            ".###.",
            "#...#",
            "....#",
            "...#.",
            "..#..",
            ".#...",
            "#####",
        ],
        "3": [
            "#####",
            "...#.",
            "..#..",
            "...#.",
            "....#",
            "#...#",
            ".###.",
        ],
        "4": [
            "...#.",
            "..##.",
            ".#.#.",
            "#..#.",
            "#####",
            "...#.",
            "...#.",
        ],
        "5": [
            "#####",
            "#....",
            "####.",
            "....#",
            "....#",
            "#...#",
            ".###.",
        ],
        "6": [
            "..##.",
            ".#...",
            "#....",
            "####.",
            "#...#",
            "#...#",
            ".###.",
        ],
        "7": [
            "#####",
            "....#",
            "...#.",
            "..#..",
            ".#...",
            ".#...",
            ".#...",
        ],
        "8": [
            ".###.",
            "#...#",
            "#...#",
            ".###.",
            "#...#",
            "#...#",
            ".###.",
        ],
        "9": [
            ".###.",
            "#...#",
            "#...#",
            ".####",
            "....#",
            "...#.",
            ".##..",
        ],
        "A": [
            ".###.",
            "#...#",
            "#...#",
            "#####",
            "#...#",
            "#...#",
            "#...#",
        ],
        "B": [
            "####.",
            "#...#",
            "#...#",
            "####.",
            "#...#",
            "#...#",
            "####.",
        ],
        "C": [
            ".###.",
            "#...#",
            "#....",
            "#....",
            "#....",
            "#...#",
            ".###.",
        ],
        "D": [
            "####.",
            "#...#",
            "#...#",
            "#...#",
            "#...#",
            "#...#",
            "####.",
        ],
        "E": [
            "#####",
            "#....",
            "#....",
            "####.",
            "#....",
            "#....",
            "#####",
        ],
        "F": [
            "#####",
            "#....",
            "#....",
            "####.",
            "#....",
            "#....",
            "#....",
        ],
        "G": [
            ".###.",
            "#...#",
            "#....",
            "#.###",
            "#...#",
            "#...#",
            ".####",
        ],
        "H": [
            "#...#",
            "#...#",
            "#...#",
            "#####",
            "#...#",
            "#...#",
            "#...#",
        ],
        "I": [
            ".###.",
            "..#..",
            "..#..",
            "..#..",
            "..#..",
            "..#..",
            ".###.",
        ],
        "J": [
            "..###",
            "...#.",
            "...#.",
            "...#.",
            "...#.",
            "#..#.",
            ".##..",
        ],
        "K": [
            "#...#",
            "#..#.",
            "#.#..",
            "##...",
            "#.#..",
            "#..#.",
            "#...#",
        ],
        "L": [
            "#....",
            "#....",
            "#....",
            "#....",
            "#....",
            "#....",
            "#####",
        ],
        "M": [
            "#...#",
            "##.##",
            "#.#.#",
            "#.#.#",
            "#...#",
            "#...#",
            "#...#",
        ],
        "N": [
            "#...#",
            "#...#",
            "##..#",
            "#.#.#",
            "#..##",
            "#...#",
            "#...#",
        ],
        "O": [
            ".###.",
            "#...#",
            "#...#",
            "#...#",
            "#...#",
            "#...#",
            ".###.",
        ],
        "P": [
            "####.",
            "#...#",
            "#...#",
            "####.",
            "#....",
            "#....",
            "#....",
        ],
        "Q": [
            ".###.",
            "#...#",
            "#...#",
            "#...#",
            "#.#.#",
            "#..#.",
            ".##.#",
        ],
        "R": [
            "####.",
            "#...#",
            "#...#",
            "####.",
            "#.#..",
            "#..#.",
            "#...#",
        ],
        "S": [
            ".####",
            "#....",
            "#....",
            ".###.",
            "....#",
            "....#",
            "####.",
        ],
        "T": [
            "#####",
            "..#..",
            "..#..",
            "..#..",
            "..#..",
            "..#..",
            "..#..",
        ],
        "U": [
            "#...#",
            "#...#",
            "#...#",
            "#...#",
            "#...#",
            "#...#",
            ".###.",
        ],
        "V": [
            "#...#",
            "#...#",
            "#...#",
            "#...#",
            "#...#",
            ".#.#.",
            "..#..",
        ],
        "W": [
            "#...#",
            "#...#",
            "#...#",
            "#.#.#",
            "#.#.#",
            "#.#.#",
            ".#.#.",
        ],
        "X": [
            "#...#",
            "#...#",
            ".#.#.",
            "..#..",
            ".#.#.",
            "#...#",
            "#...#",
        ],
        "Y": [
            "#...#",
            "#...#",
            ".#.#.",
            "..#..",
            "..#..",
            "..#..",
            "..#..",
        ],
        "Z": [
            "#####",
            "....#",
            "...#.",
            "..#..",
            ".#...",
            "#....",
            "#####",
        ],
    ]
}
