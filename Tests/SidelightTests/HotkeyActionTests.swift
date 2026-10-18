import SidelightCore
import Testing

@testable import Sidelight

struct HotkeyActionTests {
    @Test func `every action has its own Carbon identifier, which finds it again`() {
        let identifiers = HotkeyAction.allCases.map(\.carbonID)
        #expect(Set(identifiers).count == identifiers.count)
        for action in HotkeyAction.allCases {
            #expect(HotkeyAction(carbonID: action.carbonID) == action)
        }
        #expect(HotkeyAction(carbonID: 0) == nil)
    }

    @Test func `the panel's and the stash's identifiers stay what released versions registered`() {
        #expect(HotkeyAction.togglePanels.carbonID == 1 && HotkeyAction.stashClipboard.carbonID == 4)
        #expect(HotkeyAction.window(.leftHalf).carbonID == 100)
    }

    @Test func `the panel's and the stash's shortcuts come first, so they win a shared shortcut`() {
        let first: [HotkeyAction] = [.togglePanels, .closeDetails, .stashSelection, .stashClipboard]
        #expect(Array(HotkeyAction.allCases.prefix(4)) == first)
        #expect(HotkeyAction.allCases.dropFirst(4) == WindowAction.allCases.map(HotkeyAction.window)[...])
    }

    @Test func `Settings offers every shortcut, in registration order`() {
        #expect(ShortcutCatalog.all.map(\.action) == HotkeyAction.allCases)
    }
}
