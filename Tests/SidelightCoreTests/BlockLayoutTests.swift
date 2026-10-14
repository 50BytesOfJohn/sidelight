import Foundation
import Testing

@testable import SidelightCore

struct BlockLayoutTests {
    enum Block: String, WidgetBlockKind, CaseIterable {
        case header, list, footer, extra
        /// Not fixed: added and removed.
        case note1, note2

        static let fixedBlocks: [Block] = [.header, .list, .footer, .extra]

        var isShownByDefault: Bool { self != .extra }
    }

    @Test func `a new layout shows the default blocks in their declared order`() {
        let layout = BlockLayout<Block>()
        #expect(layout.shownBlocks == [.header, .list, .footer])
        #expect(layout.entries.map(\.block) == Block.fixedBlocks)
    }

    @Test func `a preset shows its blocks in its order and hides the rest`() {
        let layout = BlockLayout<Block>(shown: [.footer, .header])
        #expect(layout.shownBlocks == [.footer, .header])
        #expect(layout.entries.map(\.block) == [.footer, .header, .list, .extra])
    }

    @Test func `round-trips through JSON`() throws {
        var layout = BlockLayout<Block>(shown: [.list, .header])
        layout.setShown(.extra, true)
        let decoded = try JSONDecoder().decode(BlockLayout<Block>.self, from: JSONEncoder().encode(layout))
        #expect(decoded == layout)
    }

    @Test func `drops unknown and repeated blocks, and adds missing ones hidden`() throws {
        let json = """
            [{"block": "footer", "shown": true}, {"block": "retired", "shown": true},
             {"block": "footer", "shown": false}, {"block": "header", "shown": false}]
            """
        let layout = try JSONDecoder().decode(BlockLayout<Block>.self, from: Data(json.utf8))
        #expect(layout.entries.map(\.block) == [.footer, .header, .list, .extra])
        #expect(layout.shownBlocks == [.footer])
    }

    @Test func `hiding and showing a block keeps its place`() {
        var layout = BlockLayout<Block>()
        layout.setShown(.list, false)
        #expect(layout.shownBlocks == [.header, .footer])
        layout.setShown(.list, true)
        #expect(layout.shownBlocks == [.header, .list, .footer])
    }

    @Test func `moves blocks as a list's drag and drop reports it, hidden ones included`() {
        var layout = BlockLayout<Block>(
            entries: [
                .init(block: .header, isShown: true), .init(block: .extra, isShown: false),
                .init(block: .list, isShown: true), .init(block: .footer, isShown: true),
            ])
        layout.move(fromOffsets: [3], toOffset: 0)
        #expect(layout.entries.map(\.block) == [.footer, .header, .extra, .list])
        layout.move(fromOffsets: [0, 2], toOffset: 4)
        #expect(layout.entries.map(\.block) == [.header, .list, .footer, .extra])
        #expect(layout.shownBlocks == [.header, .list, .footer])
    }

    @Test func `moves a block up or down, and not past either end`() {
        var layout = BlockLayout<Block>()
        layout.move(.list, by: -1)
        #expect(layout.entries.map(\.block) == [.list, .header, .footer, .extra])
        layout.move(.list, by: -1)
        #expect(layout.entries.map(\.block) == [.list, .header, .footer, .extra])
        layout.move(.extra, by: 1)
        #expect(layout.entries.map(\.block) == [.list, .header, .footer, .extra])
        layout.move(.header, by: 1)
        #expect(layout.entries.map(\.block) == [.list, .footer, .header, .extra])
    }

    @Test func `added blocks join the shown ones, and only they can be removed`() throws {
        var layout = BlockLayout<Block>()
        layout.add(.note1)
        layout.add(.note2)
        layout.add(.note1)
        #expect(layout.shownBlocks == [.header, .list, .footer, .note1, .note2])
        #expect(layout.entries.map(\.block) == [.header, .list, .footer, .note1, .note2, .extra])

        layout.remove(.note1)
        layout.remove(.header)
        #expect(layout.shownBlocks == [.header, .list, .footer, .note2])

        let decoded = try JSONDecoder().decode(BlockLayout<Block>.self, from: JSONEncoder().encode(layout))
        #expect(decoded == layout)
    }

    @Test func `a preset hides added blocks rather than dropping them`() {
        var layout = BlockLayout<Block>()
        layout.add(.note1)
        layout.showOnly([.footer, .header])
        #expect(layout.shownBlocks == [.footer, .header])
        #expect(layout.contains(.note1))
        layout.setShown(.note1, true)
        #expect(layout.shownBlocks == [.footer, .header, .note1])
    }
}
