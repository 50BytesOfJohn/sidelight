import Foundation
import Testing

@testable import SidelightCore

struct StashListTests {
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    static func at(_ minutes: Double) -> Date {
        start.addingTimeInterval(minutes * 60)
    }

    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    static func item(_ n: Int, _ text: String = "", pinned: Bool = false, doneAt: Date? = nil) -> StashItem {
        StashItem(
            id: id(n), text: text.isEmpty ? "Item \(n)" : text, createdAt: start, isPinned: pinned, doneAt: doneAt)
    }

    // MARK: Adding and trimming

    @Test func `adding trims blank lines and trailing whitespace, keeping indentation`() throws {
        var list = StashList()
        let added = list.add(
            "\n \t\n    let x = 1\n    return x  \n\n  ", source: "com.apple.dt.Xcode", now: Self.start)
        let item = try #require(added)
        #expect(item.text == "    let x = 1\n    return x")
        #expect(item.title == "let x = 1")
        #expect(item.source == "com.apple.dt.Xcode")
        #expect(item.createdAt == Self.start && item.updatedAt == Self.start)
        #expect(list.items == [item])
    }

    @Test func `blank text is refused`() {
        var list = StashList()
        let added = list.add(" \n\t\r\n ", now: Self.start)
        #expect(added == nil && list.items.isEmpty)
    }

    @Test func `text is too long only once trimmed`() {
        let limit = StashList.maximumTextLength
        let fits = String(repeating: "a", count: limit) + "\n\n   \n"
        let tooLong = String(repeating: "a", count: limit + 1)
        #expect(!StashList.isTooLong(fits))
        #expect(StashList.isTooLong(tooLong))
        var list = StashList()
        let added = list.add(fits, now: Self.start)
        let refused = list.add(tooLong, now: Self.start)
        #expect(added?.text.count == limit && refused == nil)
        #expect(list.items.count == 1)
    }

    @Test func `editing trims, refuses blank text and stamps only a real change`() {
        var list = StashList(items: [Self.item(1, "Draft")])
        let blank = list.setText("   \n", of: Self.id(1), now: Self.at(1))
        let same = list.setText("Draft\n\n", of: Self.id(1), now: Self.at(1))
        #expect(!blank && !same)
        #expect(list[Self.id(1)]?.updatedAt == Self.start)
        let edited = list.setText("Final  ", of: Self.id(1), now: Self.at(2))
        #expect(edited)
        #expect(list[Self.id(1)]?.text == "Final")
        #expect(list[Self.id(1)]?.updatedAt == Self.at(2))
    }

    @Test func `the title is the first line with any text`() {
        #expect(Self.item(1, "\n   \n  Fix the login bug  \nDetails").title == "Fix the login bug")
    }

    // MARK: Pinning and done

    @Test func `pinned items are never done, and pinning reopens one`() {
        var list = StashList(items: [Self.item(1, pinned: true), Self.item(2, doneAt: Self.start)])
        let markedPinned = list.markDone(Self.id(1), now: Self.at(1))
        #expect(!markedPinned)
        let pinned = list.setPinned(true, Self.id(2), now: Self.at(1))
        #expect(pinned && list[Self.id(2)]?.isDone == false)
        // Unpinning leaves it open.
        let unpinned = list.setPinned(false, Self.id(2), now: Self.at(2))
        #expect(unpinned && list[Self.id(2)]?.isDone == false)
    }

    // MARK: Moving

    @Test func `moving into a later item's place lands just after it`() {
        var list = StashList(items: (1...4).map { Self.item($0) })
        let moved = list.move(Self.id(1), toPlaceOf: Self.id(3))
        #expect(moved)
        #expect(list.items.map(\.id) == [2, 3, 1, 4].map(Self.id))
    }

    @Test func `moving into an earlier item's place lands just before it`() {
        var list = StashList(items: (1...4).map { Self.item($0) })
        let moved = list.move(Self.id(4), toPlaceOf: Self.id(2))
        #expect(moved)
        #expect(list.items.map(\.id) == [1, 4, 2, 3].map(Self.id))
    }

    @Test func `moving onto itself or an unknown item does nothing`() {
        var list = StashList(items: (1...3).map { Self.item($0) })
        let ontoItself = list.move(Self.id(2), toPlaceOf: Self.id(2))
        let ontoUnknown = list.move(Self.id(2), toPlaceOf: Self.id(9))
        let unknown = list.move(Self.id(9), toPlaceOf: Self.id(2))
        #expect(!ontoItself && !ontoUnknown && !unknown)
        #expect(list.items.map(\.id) == [1, 2, 3].map(Self.id))
    }

    @Test func `moving by one steps over the neighbour listed, past items the list leaves out`() {
        // 2 is done, so the open list shows 1, 3, 4.
        var list = StashList(items: [Self.item(1), Self.item(2, doneAt: Self.start), Self.item(3), Self.item(4)])
        let down = list.move(Self.id(1), by: 1, among: [1, 3, 4].map(Self.id))
        #expect(down)
        #expect(list.openItems(.oldestFirst).map(\.id) == [3, 1, 4].map(Self.id))
        let up = list.move(Self.id(4), by: -1, among: [3, 1, 4].map(Self.id))
        #expect(up)
        #expect(list.openItems(.oldestFirst).map(\.id) == [3, 4, 1].map(Self.id))
    }

    @Test func `newest first lists the queue from its end, pinned items still first`() {
        #expect(Self.searchable.openItems(.newestFirst).map(\.id) == [6, 2, 3, 1].map(Self.id))
        let matches = Self.searchable.matches(order: .newestFirst)
        #expect(matches.open == Self.searchable.openItems(.newestFirst))
        // Done items go by when they were done, whatever the order.
        #expect(matches.done.map(\.id) == [5, 4].map(Self.id))
    }

    @Test func `newest first, an added item is listed on top`() {
        var list = StashList(items: (1...3).map { Self.item($0) })
        let added = list.add("Item 4", now: Self.start)
        #expect(added != nil && list.openItems(.newestFirst).first == added)
        #expect(list.items.last == added)
    }

    @Test func `newest first, moving and dragging go by the order shown, and switching back flips it unchanged`() {
        var list = StashList(items: (1...4).map { Self.item($0) })
        func shown() -> [UUID] { list.openItems(.newestFirst).map(\.id) }
        #expect(shown() == [4, 3, 2, 1].map(Self.id))
        let down = list.move(Self.id(4), by: 1, among: shown())
        #expect(down && shown() == [3, 4, 2, 1].map(Self.id))
        let up = list.move(Self.id(1), by: -1, among: shown())
        #expect(up && shown() == [3, 4, 1, 2].map(Self.id))
        // Dragged up onto 3, it lands just above it; dragged down onto 2, just below it.
        let draggedUp = list.move(Self.id(1), toPlaceOf: Self.id(3))
        #expect(draggedUp && shown() == [1, 3, 4, 2].map(Self.id))
        let draggedDown = list.move(Self.id(3), toPlaceOf: Self.id(2))
        #expect(draggedDown && shown() == [1, 4, 2, 3].map(Self.id))
        #expect(list.openItems(.oldestFirst).map(\.id) == [3, 2, 4, 1].map(Self.id))
    }

    @Test func `moving past either end, or an item not listed, does nothing`() {
        var list = StashList(items: (1...3).map { Self.item($0) })
        let listed = [1, 2, 3].map(Self.id)
        let pastTop = list.move(Self.id(1), by: -1, among: listed)
        let pastBottom = list.move(Self.id(3), by: 1, among: listed)
        let notListed = list.move(Self.id(2), by: 1, among: [1, 3].map(Self.id))
        #expect(!pastTop && !pastBottom && !notListed)
        #expect(list.items.map(\.id) == listed)
    }

    // MARK: Removing and restoring

    @Test func `a removed item is restored where it was, once`() throws {
        var list = StashList(items: (1...3).map { Self.item($0) })
        let removal = list.remove(Self.id(2))
        let removed = try #require(removal)
        #expect(removed.index == 1)
        list.restore(removed.item, at: removed.index)
        list.restore(removed.item, at: 0)
        #expect(list.items.map(\.id) == [1, 2, 3].map(Self.id))
    }

    @Test func `deleting done items goes by when they were done`() {
        var list = StashList(items: [
            Self.item(1, doneAt: Self.at(0)), Self.item(2, doneAt: Self.at(10)), Self.item(3),
            Self.item(4, pinned: true),
        ])
        let first = list.removeDone(before: Self.at(10))
        #expect(first)
        #expect(list.items.map(\.id) == [2, 3, 4].map(Self.id))
        let again = list.removeDone(before: Self.at(10))
        #expect(!again)
        let later = list.removeDone(before: Self.at(11))
        #expect(later)
        #expect(list.items.map(\.id) == [3, 4].map(Self.id))
    }

    // MARK: Searching

    /// Queue order: 1, pinned 2, 3, done 4 (earlier), done 5 (later), pinned 6.
    static let searchable = StashList(items: [
        item(1, "Fix the login bug"),
        item(2, "Review prompt: check login and logout", pinned: true),
        item(3, "Write the Résumé section"),
        item(4, "Login copy for the landing page", doneAt: at(1)),
        item(5, "Rename the LOGIN button", doneAt: at(5)),
        item(6, "Commit message template", pinned: true),
    ])

    @Test func `without a search, open items list pinned first, and done ones most recently done first`() {
        let matches = Self.searchable.matches()
        #expect(matches.open.map(\.id) == [2, 6, 1, 3].map(Self.id))
        #expect(matches.done.map(\.id) == [5, 4].map(Self.id))
        #expect(matches[.all].map(\.id) == [2, 6, 1, 3, 5, 4].map(Self.id))
        #expect(matches.open == Self.searchable.openItems(.oldestFirst))
    }

    @Test func `every word must appear, ignoring case, accents and order`() {
        #expect(Self.searchable.matches(search: StashSearch("LOGIN")).open.map(\.id) == [2, 1].map(Self.id))
        #expect(Self.searchable.matches(search: StashSearch("  bug   fix ")).open.map(\.id) == [Self.id(1)])
        #expect(Self.searchable.matches(search: StashSearch("resume")).open.map(\.id) == [Self.id(3)])
        #expect(Self.searchable.matches(search: StashSearch("login")).done.map(\.id) == [5, 4].map(Self.id))
        #expect(Self.searchable.matches(search: StashSearch("nothing like it"))[.all].isEmpty)
    }

    @Test func `pinned only lists pinned items`() {
        let matches = Self.searchable.matches(search: StashSearch("login"), pinnedOnly: true)
        #expect(matches.open.map(\.id) == [Self.id(2)])
        #expect(matches.done.isEmpty)
    }

    @Test func `the item being edited is listed whatever the search, in its place`() {
        let search = StashSearch("résumé")
        #expect(Self.searchable.matches(search: search, keeping: Self.id(1)).open.map(\.id) == [1, 3].map(Self.id))
        #expect(Self.searchable.matches(search: search, keeping: Self.id(4)).done.map(\.id) == [Self.id(4)])
        // Pinned only still applies to it.
        #expect(Self.searchable.matches(search: search, pinnedOnly: true, keeping: Self.id(1))[.all].isEmpty)
    }
}

struct StashFileTests {
    static func list(_ json: String) throws -> StashList {
        try StashList(json: Data(json.utf8))
    }

    /// What this version writes for a done item from Safari and a pinned one typed in.
    static let file = """
        {
          "items" : [
            {
              "createdAt" : "2026-10-01T09:00:00Z",
              "doneAt" : "2026-10-02T10:30:00Z",
              "id" : "00000000-0000-4000-8000-000000000001",
              "pinned" : false,
              "source" : "com.apple.Safari",
              "text" : "Fix the login bug\\nSteps: …",
              "updatedAt" : "2026-10-02T10:30:00Z"
            },
            {
              "createdAt" : "2026-10-01T09:05:00Z",
              "id" : "00000000-0000-4000-8000-000000000002",
              "pinned" : true,
              "text" : "Review https://example.com/prompt",
              "updatedAt" : "2026-10-01T09:05:00Z"
            }
          ],
          "version" : 1
        }
        """

    @Test func `writes the stash file in its released format, and reads it back unchanged`() throws {
        let created = try Date("2026-10-01T09:00:00Z", strategy: .iso8601)
        let done = try Date("2026-10-02T10:30:00Z", strategy: .iso8601)
        let list = StashList(items: [
            StashItem(
                id: StashListTests.id(1), text: "Fix the login bug\nSteps: …", createdAt: created, updatedAt: done,
                source: "com.apple.Safari", doneAt: done),
            StashItem(
                id: StashListTests.id(2), text: "Review https://example.com/prompt",
                createdAt: created.addingTimeInterval(300), isPinned: true),
        ])
        #expect(String(decoding: try list.json(), as: UTF8.self) == Self.file)
        let read = try Self.list(Self.file)
        #expect(read == list && !read.droppedOnLoad)
        #expect(try read.json() == Data(Self.file.utf8))
    }

    @Test func `an item needs only an ID and text`() throws {
        let before = Date.now
        let list = try Self.list(
            #"{"version": 1, "items": [{"id": "00000000-0000-4000-8000-000000000001", "text": "Hi"}]}"#)
        let item = try #require(list.items.first)
        #expect(item.text == "Hi" && !item.isPinned && !item.isDone && item.source == nil)
        #expect(item.createdAt >= before && item.updatedAt == item.createdAt)
        #expect(!list.droppedOnLoad)
    }

    @Test func `an odd field takes its default rather than losing the item`() throws {
        let list = try Self.list(
            """
            {"version": 1, "items": [{
              "id": "00000000-0000-4000-8000-000000000001", "text": "Hi", "createdAt": "2026-10-01T09:00:00Z",
              "updatedAt": "yesterday", "source": 7, "pinned": "yes", "doneAt": 42, "color": "red"
            }]}
            """)
        let item = try #require(list.items.first)
        #expect(item.updatedAt == item.createdAt)
        #expect(item.source == nil && !item.isPinned && item.doneAt == nil)
        #expect(!list.droppedOnLoad)
    }

    @Test func `a pinned item written as done is read as open`() throws {
        let list = try Self.list(
            """
            {"version": 1, "items": [{"id": "00000000-0000-4000-8000-000000000001", "text": "Hi", "pinned": true,
              "doneAt": "2026-10-01T09:00:00Z"}]}
            """)
        #expect(list.items.first?.isPinned == true && list.items.first?.isDone == false)
    }

    @Test func `an item that can't be read is left out, and noted`() throws {
        let list = try Self.list(
            """
            {"version": 1, "items": [
              {"id": "00000000-0000-4000-8000-000000000001", "text": "Kept"},
              {"id": "not-a-uuid", "text": "Bad ID"},
              {"id": "00000000-0000-4000-8000-000000000003"},
              {"id": "00000000-0000-4000-8000-000000000004", "text": "Also kept"}
            ]}
            """)
        #expect(list.items.map(\.text) == ["Kept", "Also kept"])
        #expect(list.droppedOnLoad)
    }

    @Test func `a duplicate ID keeps the first item, and is noted`() throws {
        let list = try Self.list(
            """
            {"version": 1, "items": [
              {"id": "00000000-0000-4000-8000-000000000001", "text": "First"},
              {"id": "00000000-0000-4000-8000-000000000002", "text": "Other"},
              {"id": "00000000-0000-4000-8000-000000000001", "text": "Copy"}
            ]}
            """)
        #expect(list.items.map(\.text) == ["First", "Other"])
        #expect(list.droppedOnLoad)
    }

    @Test func `a later version's file is read as far as it can be, and noted`() throws {
        let list = try Self.list(
            #"{"version": 2, "items": [{"id": "00000000-0000-4000-8000-000000000001", "text": "Hi", "tags": ["a"]}]}"#)
        #expect(list.items.map(\.text) == ["Hi"])
        #expect(list.droppedOnLoad)
        // Saving writes this version's format.
        #expect(try StashList(json: list.json()).droppedOnLoad == false)
    }

    @Test(arguments: [#"{"items": []}"#, #"{"version": 1}"#, #"[]"#, "not json"])
    func `a file without a version or items is invalid`(json: String) {
        #expect(throws: (any Error).self) { try Self.list(json) }
    }
}

struct StashOptionsTests {
    static func options(_ json: String) throws -> StashOptions {
        try JSONDecoder().decode(StashOptions.self, from: Data(json.utf8))
    }

    @Test func `missing options take their defaults`() throws {
        let options = try Self.options("{}")
        #expect(options == StashOptions())
        #expect(options.captureHotkey == .defaultStashCapture && options.clipboardHotkey == .defaultStashClipboard)
        #expect(options.deleteDoneAfterDays == 7)
        #expect(options.excludes("com.1password.1password") && !options.excludes(nil))
        #expect(options.copiesSelectionWithCommandC)
        #expect(options.order == .oldestFirst)
    }

    @Test(
        arguments: [
            (#""newestFirst""#, .newestFirst), (#""oldestFirst""#, .oldestFirst), (#""sideways""#, .oldestFirst),
            ("1", .oldestFirst),
        ] as [(String, StashOrder)])
    func `the order is oldest first unless set to newest first`(value: String, order: StashOrder) throws {
        #expect(try Self.options(#"{"order": \#(value)}"#).order == order)
    }

    @Test(arguments: [("false", false), ("true", true), (#""no""#, true), ("null", true)] as [(String, Bool)])
    func `copying the selection with ⌘C is on unless turned off`(value: String, copies: Bool) throws {
        #expect(try Self.options(#"{"copiesSelectionWithCommandC": \#(value)}"#).copiesSelectionWithCommandC == copies)
    }

    @Test func `set options read back unchanged`() throws {
        var options = StashOptions()
        options.captureHotkey = Hotkey(keyCode: 1, modifiers: [.control, .shift], key: "S")
        options.clipboardHotkey = Hotkey(keyCode: 11, modifiers: [.option, .command], key: "B")
        options.deleteDoneAfterDays = 30
        options.excludedApps = ["com.example.Vault"]
        options.copiesSelectionWithCommandC = false
        options.order = .newestFirst
        let read = try JSONDecoder().decode(StashOptions.self, from: JSONEncoder().encode(options))
        #expect(read == options)
        #expect(!read.excludes("com.1password.1password") && read.excludes("com.example.Vault"))
    }

    @Test(
        arguments: [
            ("0", 0), ("1", 1), ("365", 365), ("400", 365), ("-3", 0), (#""week""#, 7), ("null", 7),
        ] as [(String, Int)])
    func `days before deleting done items are kept within what the settings offer`(value: String, days: Int) throws {
        #expect(try Self.options(#"{"deleteDoneAfterDays": \#(value)}"#).deleteDoneAfterDays == days)
    }

    @Test func `0 days keeps done items for good`() {
        var options = StashOptions()
        options.deleteDoneAfterDays = 0
        #expect(options.deleteDonePeriod == nil)
        options.deleteDoneAfterDays = 3
        #expect(options.deleteDonePeriod == TimeInterval(3 * 24 * 60 * 60))
    }

    @Test func `a shortcut without ⌘, ⌥ or ⌃, or one that can't be read, takes its default`() throws {
        let options = try Self.options(
            """
            {"captureHotkey": {"keyCode": 8, "modifiers": 512, "key": "C"}, "clipboardHotkey": "⌃V",
             "deleteDoneAfterDays": 14, "excludedApps": 3}
            """)
        #expect(options.captureHotkey == .defaultStashCapture)
        #expect(options.clipboardHotkey == .defaultStashClipboard)
        #expect(options.deleteDoneAfterDays == 14)
        #expect(options.excludedApps == StashOptions.defaultExcludedApps)
    }

    @Test func `a configuration without stash options, or with unreadable ones, keeps everything else`() throws {
        var configuration = AppConfiguration()
        configuration.windowAvoidance = .clip
        var file = try #require(try JSONSerialization.jsonObject(with: configuration.json()) as? [String: Any])
        #expect(file["stash"] != nil)
        for stash in [nil, "everything" as Any] {
            file["stash"] = stash
            let read = try AppConfiguration(json: JSONSerialization.data(withJSONObject: file))
            #expect(read == configuration)
        }
    }

    @Test(arguments: [(0, 1), (4, 4), (50, 10)])
    func `a widget's item count is kept within what the settings offer`(value: Int, count: Int) throws {
        let settings = try JSONDecoder().decode(StashSettings.self, from: Data(#"{"itemCount": \#(value)}"#.utf8))
        #expect(settings.itemCount == count && settings.showsTwoLines && settings.showsSourceIcons)
    }
}

struct ClipboardRestoreTests {
    @Test func `an empty clipboard can be put back`() {
        #expect(ClipboardRestore.unrestorableType(in: []) == nil)
        #expect(ClipboardRestore.unrestorableType(in: [[]]) == nil)
    }

    @Test func `text in any form, links and clipboard markers can be put back`() {
        let copiedFromABrowser = [
            "public.html", "public.utf8-plain-text", "public.utf16-external-plain-text", "public.rtf",
            "public.url", "public.url-name", "org.nspasteboard.source", "org.nspasteboard.TransientType",
        ]
        #expect(ClipboardRestore.unrestorableType(in: [copiedFromABrowser, ["public.swift-source"]]) == nil)
    }

    @Test func `images, files and private formats can't`() {
        #expect(ClipboardRestore.unrestorableType(in: [["public.utf8-plain-text"], ["public.png"]]) == "public.png")
        #expect(ClipboardRestore.unrestorableType(in: [["public.file-url"]]) == "public.file-url")
        #expect(
            ClipboardRestore.unrestorableType(in: [["com.apple.NSFilePromiseItemMetaData"]])
                == "com.apple.NSFilePromiseItemMetaData")
        #expect(ClipboardRestore.unrestorableType(in: [["dyn.ah62d4rv4gu8y"]]) == "dyn.ah62d4rv4gu8y")
        #expect(ClipboardRestore.unrestorableType(in: [["com.example.private"]]) == "com.example.private")
    }
}

extension ClipboardRestoreTests {
    @Test func `plain text macOS lists without data can be left out beside the plain text an app wrote`() {
        let written = ["public.utf8-plain-text", "public.html"]
        #expect(ClipboardRestore.canOmitUnreadable("public.utf16-external-plain-text", besideReadable: written))
        #expect(
            !ClipboardRestore.canOmitUnreadable("public.utf16-external-plain-text", besideReadable: ["public.html"]))
        #expect(!ClipboardRestore.canOmitUnreadable("public.html", besideReadable: written))
        #expect(!ClipboardRestore.canOmitUnreadable("public.png", besideReadable: written))
    }
}
