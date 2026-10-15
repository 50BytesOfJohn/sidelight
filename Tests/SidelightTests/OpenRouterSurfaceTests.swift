import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import Sidelight
@testable import SidelightCore

struct OpenRouterSurfaceTests {
    /// A stash the sessions need but never use: its file is never written, as nothing changes it.
    static let stash = StashStore(
        fileURL: FileManager.default.temporaryDirectory.appending(path: "sidelight-unused-stash-\(UUID()).json"),
        deleteDoneAfter: nil)
    @Test func `details retain public demand independently of an unseen covered main surface`() {
        let widget = WidgetInstance(settings: .openRouter(.init(sync: .manual)))
        var config = AppConfiguration()
        config.sections = [
            PanelSection(widgets: [widget, WidgetInstance(settings: .openRouter(.init(preset: .credits)))])
        ]
        let session = DetailsSession(
            displayID: "fixture-display", widgetID: widget.id,
            request: .openRouterModels(filter: .all, sort: .latestAdded), stash: Self.stash)
        // The main panel contributes no demand; the independent details session still needs public models.
        var demand = config.openRouterDemand(panels: [])
        demand.merge(session.openRouterDemand(in: config))
        #expect(demand.catalogue == .manual && !demand.needsAccount)
        let preview = config.openRouterDemand(panels: [], previewsEveryWidget: true)
        #expect(preview.catalogue == .manual && !preview.needsAccount)
    }

    @Test func `session replacement resets browsing state and leaves the previous browser intact`() {
        let session = DetailsSession(
            displayID: "fixture-display", widgetID: UUID(),
            request: .openRouterModels(filter: .textOutput, sort: .latestAdded), stash: Self.stash)
        guard case .openRouterModels(let browser) = session.content else { return }
        browser.search = "fixture"
        browser.expandedID = "fixture/one"
        browser.sort = .context
        // Reading the session preserves its browser; replacing content is a separate operation.
        guard case .openRouterModels(let retained) = session.content else { return }
        #expect(retained === browser && retained.search == "fixture" && retained.expandedID == "fixture/one")
        let id = session.contentID
        session.replace(widgetID: UUID(), request: .openRouterModels(filter: .all, sort: .inputPrice))
        guard case .openRouterModels(let replacement) = session.content else { return }
        #expect(session.contentID != id && replacement !== browser)
        #expect(replacement.search.isEmpty && replacement.expandedID == nil)
        #expect(replacement.filter == .all && replacement.sort == .inputPrice)
    }

    @Test func `details clock stops for occlusion and explicit hide`() throws {
        let screen = try #require(NSScreen.screens.first)
        let display = try #require(Display(screen, isMain: true))
        let layout = DetailsLayout(placement: DetailsPlacement(display: display, replacing: .left))
        #expect(!layout.isOnScreen)
        layout.isShown = true
        #expect(layout.isOnScreen)
        layout.isOccluded = true
        #expect(!layout.isOnScreen)
        layout.isShown = false
        layout.isOccluded = false
        #expect(!layout.isOnScreen)
    }

    @Test(arguments: [(kVK_Space, "Space"), (kVK_Return, "↩"), (kVK_F1, "F1"), (kVK_LeftArrow, "←")])
    func `recorder maps physical special keys and modifiers`(code: Int, name: String) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.control, .option, .command, .shift, .capsLock],
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: UInt16(code)))
        let hotkey = try #require(Hotkey(event: event))
        #expect(hotkey.keyCode == UInt32(code) && hotkey.key == name)
        #expect(hotkey.modifiers == [.control, .option, .command, .shift])
        var renamed = hotkey
        renamed.key = "Localized label"
        #expect(hotkey.isSameShortcut(as: renamed))
        renamed.modifiers.remove(.shift)
        #expect(!hotkey.isSameShortcut(as: renamed))
    }

    @Test func `recorder rejects unmodified and shift-only typing`() throws {
        for flags: NSEvent.ModifierFlags in [[], [.shift], [.capsLock]] {
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: 0, context: nil, characters: "s", charactersIgnoringModifiers: "s",
                    isARepeat: false, keyCode: UInt16(kVK_ANSI_S)))
            #expect(Hotkey(event: event) == nil)
        }
    }
}
