import Foundation

/// The pieces a widget built from blocks can show, like the Railway widget's services and bill. The raw value is
/// the stable identifier stored in `config.json`.
///
/// Most blocks are fixed: every widget has each once, shown or not. Others can be added any number of times, each
/// with its own options, like the Railway widget's one service in detail; their raw values carry an instance ID.
public protocol WidgetBlockKind: RawRepresentable<String>, Hashable, Sendable {
    /// The fixed blocks, in their default order.
    static var fixedBlocks: [Self] { get }

    /// Whether a new widget shows it. A block that a later version adds to a saved layout starts hidden instead,
    /// so a layout someone arranged doesn't change under them.
    var isShownByDefault: Bool { get }
}

extension WidgetBlockKind {
    /// Whether every widget has this block, rather than having it added.
    public var isFixed: Bool { Self.fixedBlocks.contains(self) }
}

/// Which blocks a widget shows, top to bottom. Every fixed block appears exactly once, shown or not, and a hidden
/// block keeps its place and its options, so showing it again puts it back where it was. Added blocks stay until
/// they're removed.
///
/// Stored as `[{"block": "services", "shown": true}, …]`. Unknown blocks (from a newer version, or retired) are
/// dropped, and fixed blocks the saved layout lacks are added hidden, so any saved layout loads.
public struct BlockLayout<Block: WidgetBlockKind>: Hashable, Sendable {
    public struct Entry: Hashable, Sendable, Identifiable {
        public var block: Block
        public var isShown: Bool

        public var id: Block { block }

        public init(block: Block, isShown: Bool) {
            self.block = block
            self.isShown = isShown
        }
    }

    public private(set) var entries: [Entry]

    /// Every block in its declared order, shown as ``WidgetBlockKind/isShownByDefault`` says.
    public init() {
        entries = Block.fixedBlocks.map { Entry(block: $0, isShown: $0.isShownByDefault) }
    }

    /// `shown` in that order, then every other block hidden: a preset.
    public init(shown: [Block]) {
        self.init(entries: shown.map { Entry(block: $0, isShown: true) })
    }

    /// `entries` without duplicates, followed by any missing fixed block, hidden.
    public init(entries: [Entry]) {
        var seen = Set<Block>()
        var normalized = entries.filter { seen.insert($0.block).inserted }
        normalized += Block.fixedBlocks.filter { !seen.contains($0) }.map { Entry(block: $0, isShown: false) }
        self.entries = normalized
    }

    /// Shows `blocks` in that order at the top, and hides every other block, added ones included: a preset.
    public mutating func showOnly(_ blocks: [Block]) {
        let others = entries.filter { !blocks.contains($0.block) }.map { Entry(block: $0.block, isShown: false) }
        self = BlockLayout(entries: blocks.map { Entry(block: $0, isShown: true) } + others)
    }

    /// Adds a block that isn't fixed, shown, at the end of the shown blocks.
    public mutating func add(_ block: Block) {
        guard !entries.contains(where: { $0.block == block }) else { return }
        let index = (entries.lastIndex { $0.isShown }).map { $0 + 1 } ?? 0
        entries.insert(Entry(block: block, isShown: true), at: index)
    }

    /// Removes a block that was added. Fixed blocks can only be hidden.
    public mutating func remove(_ block: Block) {
        guard !block.isFixed else { return }
        entries.removeAll { $0.block == block }
    }

    public func contains(_ block: Block) -> Bool {
        entries.contains { $0.block == block }
    }

    /// The blocks to draw, in order.
    public var shownBlocks: [Block] { entries.filter(\.isShown).map(\.block) }

    public func isShown(_ block: Block) -> Bool {
        entries.contains { $0.block == block && $0.isShown }
    }

    public mutating func setShown(_ block: Block, _ isShown: Bool) {
        guard let index = entries.firstIndex(where: { $0.block == block }) else { return }
        entries[index].isShown = isShown
    }

    /// Swaps `block` with the shown block `offset` places away: -1 for up, 1 for down. Hidden blocks in between
    /// are skipped, since they aren't drawn.
    public mutating func moveAmongShown(_ block: Block, by offset: Int) {
        var order = shownBlocks
        guard let position = order.firstIndex(of: block), order.indices.contains(position + offset) else { return }
        order.swapAt(position, position + offset)
        reorderShown(order)
    }

    /// Reorders the shown blocks as `order` lists them; hidden blocks keep their places among the rest.
    public mutating func reorderShown(_ order: [Block]) {
        let shownSlots = entries.indices.filter { entries[$0].isShown }
        let current = shownSlots.map { entries[$0] }
        var queue = order.compactMap { block in current.first { $0.block == block } }
        queue += current.filter { entry in !queue.contains { $0.block == entry.block } }
        for (slot, entry) in zip(shownSlots, queue) { entries[slot] = entry }
    }
}

extension BlockLayout: Codable {
    private struct StoredEntry: Codable {
        var block: String
        var shown: Bool
    }

    public init(from decoder: any Decoder) throws {
        let stored = try decoder.singleValueContainer().decode([StoredEntry].self)
        self.init(
            entries: stored.compactMap { entry in
                Block(rawValue: entry.block).map { Entry(block: $0, isShown: entry.shown) }
            })
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries.map { StoredEntry(block: $0.block.rawValue, shown: $0.isShown) })
    }
}
