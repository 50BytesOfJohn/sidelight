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

    @Test func `reordering the shown blocks leaves hidden ones where they are`() {
        var layout = BlockLayout<Block>(
            entries: [
                .init(block: .header, isShown: true), .init(block: .extra, isShown: false),
                .init(block: .list, isShown: true), .init(block: .footer, isShown: true),
            ])
        layout.reorderShown([.footer, .header, .list])
        #expect(layout.entries.map(\.block) == [.footer, .extra, .header, .list])
        #expect(layout.shownBlocks == [.footer, .header, .list])
    }

    @Test func `moves a block past hidden neighbors`() {
        var layout = BlockLayout<Block>(
            entries: [
                .init(block: .header, isShown: true), .init(block: .extra, isShown: false),
                .init(block: .list, isShown: true), .init(block: .footer, isShown: true),
            ])
        layout.moveAmongShown(.list, by: -1)
        #expect(layout.shownBlocks == [.list, .header, .footer])
        layout.moveAmongShown(.list, by: -1)
        #expect(layout.shownBlocks == [.list, .header, .footer])
        layout.moveAmongShown(.footer, by: 1)
        #expect(layout.shownBlocks == [.list, .header, .footer])
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
