import CoreGraphics
import Foundation

/// Where a launcher's icons go: how many columns fit, which apps show, and whether the last cell is the All-apps tile
/// or a "+N" for the apps that don't fit. Views only draw what this says.
///
/// Pinned apps come first. Running apps that aren't pinned (the "extra" ones) start a new row after a divider, as the
/// Dock shows them. The tile takes the cell after the last app; when apps don't fit, it becomes "+N" in place of the
/// last app that would, so it never sits alone on a row of its own just for the overflow.
public struct LauncherGrid: Equatable, Sendable {
    public struct Input: Sendable {
        public var width: Double
        public var iconSize: Double
        public var spacing: Double
        /// 0: as many as fit.
        public var fixedColumns: Int
        /// 0: no limit.
        public var rowLimit: Int
        public var pinnedCount: Int
        /// Running apps that aren't pinned, after a divider.
        public var extraCount: Int
        public var showsAllAppsTile: Bool
        /// The height of a name under each icon; 0 without names.
        public var labelHeight: Double

        public init(
            width: Double, iconSize: Double, spacing: Double, fixedColumns: Int = 0, rowLimit: Int = 0,
            pinnedCount: Int, extraCount: Int = 0, showsAllAppsTile: Bool = true, labelHeight: Double = 0
        ) {
            self.width = width
            self.iconSize = iconSize
            self.spacing = spacing
            self.fixedColumns = fixedColumns
            self.rowLimit = rowLimit
            self.pinnedCount = pinnedCount
            self.extraCount = extraCount
            self.showsAllAppsTile = showsAllAppsTile
            self.labelHeight = labelHeight
        }
    }

    /// One cell of the grid.
    public enum Cell: Hashable, Sendable {
        /// The pinned app at this index.
        case pinned(Int)
        /// The extra running app at this index.
        case extra(Int)
        /// The All-apps tile, or "+N" when ``LauncherGrid/overflow`` isn't 0.
        case tile
    }

    /// The room under each icon for the running dot.
    public static let indicatorHeight = 6.0

    /// At least 1. Fixed columns are reduced to what fits, so the grid never clips.
    public var columns: Int
    public var visiblePinned: Int
    public var visibleExtra: Int
    /// Apps hidden; more than 0 turns the tile into "+N".
    public var overflow: Int
    public var showsTile: Bool
    /// The width of each column, centring its icon.
    public var cellSize: Double
    /// The height of each row: the icon, the dot's room, and the name.
    public var rowHeight: Double
    public var spacing: Double
    /// Row by row.
    public var rows: [[Cell]]
    /// The first row of extra running apps, which the divider goes above.
    public var dividerBeforeRow: Int?

    /// Apps drawn before the tile.
    public var visibleItems: Int { visiblePinned + visibleExtra }

    /// The grid's width: its columns and the gaps between them.
    public var width: Double {
        Double(columns) * cellSize + Double(max(columns - 1, 0)) * spacing
    }

    public init(_ input: Input) {
        let iconSize = max(input.iconSize, 1)
        let spacing = max(input.spacing, 0)
        let fitting = max(1, Int(((input.width + spacing) / (iconSize + spacing)).rounded(.down)))
        let columns = input.fixedColumns > 0 ? min(input.fixedColumns, fitting) : fitting
        let spread = max((input.width - spacing * Double(columns - 1)) / Double(columns), iconSize)
        // As many as fit spread across the width; fewer, fixed ones keep to the icon (wider with names) and centre.
        let cellSize = columns == fitting ? spread : min(spread, input.labelHeight > 0 ? iconSize + 16 : iconSize)
        self.init(
            columns: columns, rowLimit: input.rowLimit, pinned: max(input.pinnedCount, 0),
            extra: max(input.extraCount, 0), showsAllAppsTile: input.showsAllAppsTile, cellSize: cellSize,
            rowHeight: iconSize + Self.indicatorHeight + max(input.labelHeight, 0), spacing: spacing)
    }

    private init(
        columns: Int, rowLimit: Int, pinned: Int, extra: Int, showsAllAppsTile: Bool, cellSize: Double,
        rowHeight: Double, spacing: Double
    ) {
        self.columns = columns
        self.cellSize = cellSize
        self.rowHeight = rowHeight
        self.spacing = spacing
        let limit = rowLimit > 0 ? rowLimit : Int.max

        func rowCount(pinned: Int, extra: Int, tile: Bool) -> Int {
            let tile = tile ? 1 : 0
            guard extra > 0 else { return Self.ceilDiv(pinned + tile, columns) }
            return Self.ceilDiv(pinned, columns) + Self.ceilDiv(extra + tile, columns)
        }

        if rowCount(pinned: pinned, extra: extra, tile: showsAllAppsTile) <= limit {
            visiblePinned = pinned
            visibleExtra = extra
            overflow = 0
            showsTile = showsAllAppsTile
        } else {
            // The most apps that fit with a "+N" after them: pinned ones first.
            var shown = pinned + extra - 1
            while shown > 0,
                rowCount(pinned: min(shown, pinned), extra: max(shown - pinned, 0), tile: true) > limit
            {
                shown -= 1
            }
            visiblePinned = min(shown, pinned)
            visibleExtra = max(shown - pinned, 0)
            overflow = pinned + extra - shown
            showsTile = true
        }

        var rows: [[Cell]] = []
        var cells = (0..<visiblePinned).map(Cell.pinned)
        if visibleExtra > 0 {
            rows = Self.chunked(cells, columns)
            cells = (0..<visibleExtra).map(Cell.extra)
            dividerBeforeRow = rows.isEmpty ? nil : rows.count
        } else {
            dividerBeforeRow = nil
        }
        if showsTile { cells.append(.tile) }
        rows += Self.chunked(cells, columns)
        self.rows = rows
    }

    /// Where a drop at `point` (in the grid's own coordinates, rows from the top) would insert among the pinned apps,
    /// from 0 to ``visiblePinned``: the gap nearest to it.
    public func insertionIndex(at point: CGPoint) -> Int {
        guard visiblePinned > 0 else { return 0 }
        let pinnedRows = Self.ceilDiv(visiblePinned, columns)
        guard point.y >= 0 else { return 0 }
        let row = Int((Double(point.y) + spacing / 2) / (rowHeight + spacing))
        guard row < pinnedRows else { return visiblePinned }
        let pitch = cellSize + spacing
        let column = Int(((Double(point.x) + pitch / 2) / pitch).rounded(.down)).clamped(to: 0...columns)
        return (row * columns + column).clamped(to: 0...visiblePinned)
    }

    /// One row of `limit` icons, then the tile: "+N" for the rest, when there are more.
    public static func bar(count: Int, limit: Int, showsAllAppsTile: Bool) -> LauncherGrid {
        let shown = min(max(count, 0), max(limit, 0))
        let overflow = max(count, 0) - shown
        return LauncherGrid(
            columns: max(1, shown + (showsAllAppsTile || overflow > 0 ? 1 : 0)), rowLimit: 1, pinned: shown, extra: 0,
            showsAllAppsTile: showsAllAppsTile || overflow > 0, cellSize: 0, rowHeight: 0, spacing: 0
        )
        .withOverflow(overflow)
    }

    /// One icon a row, up to `rowLimit` rows (0: every app), the tile included.
    public static func column(count: Int, rowLimit: Int, showsAllAppsTile: Bool) -> LauncherGrid {
        LauncherGrid(
            columns: 1, rowLimit: rowLimit, pinned: max(count, 0), extra: 0, showsAllAppsTile: showsAllAppsTile,
            cellSize: 0, rowHeight: 0, spacing: 0)
    }

    private func withOverflow(_ overflow: Int) -> LauncherGrid {
        var grid = self
        grid.overflow = overflow
        return grid
    }

    private static func ceilDiv(_ value: Int, _ divisor: Int) -> Int {
        (value + divisor - 1) / divisor
    }

    private static func chunked(_ cells: [Cell], _ size: Int) -> [[Cell]] {
        stride(from: 0, to: cells.count, by: size).map { Array(cells[$0..<min($0 + size, cells.count)]) }
    }
}
