import Foundation

extension PixelLine {
    /// A battery drawn in dots, as tall as a line of ``PixelFont`` text: a lit outline and terminal around `segments`
    /// bars, as many lit as the charge fills, a started bar counting whole so any charge shows one.
    ///
    ///     ##################
    ///     #................#
    ///     #.##.##.##.##....##
    ///     #.##.##.##.##....##   62 %: four of five bars
    ///     #.##.##.##.##....##
    ///     #................#
    ///     ##################
    public static func batteryCell(percent: Int, segments: Int = 5) -> PixelLine {
        let segments = max(1, segments)
        let percent = percent.clamped(to: 0...100)
        // Outline, a dot of space, bars two dots wide with a dot between them, a dot of space, outline.
        let width = 3 * segments + 3
        let litBars = (percent * segments + 99) / 100
        var lit: [PixelPoint] = []
        var unlit: [PixelPoint] = []
        for row in 0..<PixelFont.height {
            for column in 0..<width {
                let isOutline = row == 0 || row == PixelFont.height - 1 || column == 0 || column == width - 1
                let bar = (column - 2) / 3
                let isBar = (2...4).contains(row) && column >= 2 && column < width - 2 && (column - 2) % 3 != 2
                let point = PixelPoint(column: column, row: row)
                if isOutline || (isBar && bar < litBars) { lit.append(point) } else { unlit.append(point) }
            }
            // The terminal, a dot wide, beside the middle rows.
            if (2...4).contains(row) { lit.append(PixelPoint(column: width, row: row)) }
        }
        return PixelLine(columns: width + 1, lit: lit, unlit: unlit)
    }
}
