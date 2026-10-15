import Foundation
import Testing

@testable import Sidelight
@testable import SidelightCore

struct StashStoreTests {
    let directory = URL.temporaryDirectory.appending(path: "sidelight-stash-\(UUID().uuidString)")
    var file: URL { directory.appending(path: "stash/items.json") }

    init() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func backups(_ reason: String) -> [URL] {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil))
        return (contents ?? []).filter { $0.lastPathComponent.hasPrefix("items.\(reason)-") }
    }

    private func saved() throws -> StashList {
        try StashList(json: Data(contentsOf: file))
    }

    private func write(_ items: [StashItem], version: Int = 1) throws {
        var json = try #require(
            try JSONSerialization.jsonObject(with: StashList(items: items).json()) as? [String: Any])
        json["version"] = version
        try JSONSerialization.data(withJSONObject: json).write(to: file)
    }

    @Test func `nothing is written until something is stashed, then it's saved`() throws {
        let store = StashStore(fileURL: file, deleteDoneAfter: nil)
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: file.path()))
        let added = try store.add("  Ship it  \n").get()
        store.flush()
        // The file keeps whole seconds, so compare what was stashed rather than when.
        #expect(try saved().items.map(\.id) == [added.id])
        #expect(try saved().items.map(\.text) == ["  Ship it"])
        #expect(!store.hasSaveFailed)
    }

    @Test func `blank and overlong text say why they're refused`() {
        let store = StashStore(fileURL: file, deleteDoneAfter: nil)
        #expect(throws: StashStore.Refusal.blank) { try store.add(" \n ").get() }
        #expect(throws: StashStore.Refusal.tooLong) {
            try store.add(String(repeating: "a", count: StashList.maximumTextLength + 1)).get()
        }
        #expect(store.list.items.isEmpty)
    }

    @Test func `done items are deleted once kept long enough, and never with no period`() throws {
        let old = StashItem(text: "Old", createdAt: .now - 30 * 86_400, doneAt: .now - 10 * 86_400)
        let recent = StashItem(text: "Recent", createdAt: .now - 86_400, doneAt: .now - 86_400)
        let open = StashItem(text: "Open", createdAt: .now - 30 * 86_400)
        try write([old, recent, open])

        let keeping = StashStore(fileURL: file, deleteDoneAfter: nil)
        #expect(keeping.list.items.count == 3)
        keeping.deleteDoneAfter = 7 * 86_400
        #expect(keeping.list.items.map(\.text) == ["Recent", "Open"])

        let deleting = StashStore(fileURL: file, deleteDoneAfter: 7 * 86_400)
        #expect(deleting.list.items.map(\.text) == ["Recent", "Open"])
    }

    @Test func `an invalid file is kept aside, and the stash starts empty`() throws {
        let broken = Data("{ not json".utf8)
        try broken.write(to: file)
        let store = StashStore(fileURL: file, deleteDoneAfter: nil)
        #expect(store.list.items.isEmpty && !store.hasSaveFailed)
        #expect(try backups("invalid").map { try Data(contentsOf: $0) } == [broken])
        #expect(!FileManager.default.fileExists(atPath: file.path()))
    }

    @Test func `a later version's file is kept aside before the first save over it`() throws {
        try write([StashItem(text: "From the future", createdAt: .now)], version: 2)
        let original = try Data(contentsOf: file)
        let store = StashStore(fileURL: file, deleteDoneAfter: nil)
        #expect(store.list.items.map(\.text) == ["From the future"])
        store.flush()
        // Nothing changed, so nothing is written.
        #expect(backups("unsupported").isEmpty)
        #expect(try Data(contentsOf: file) == original)

        _ = store.add("Now")
        store.flush()
        #expect(try backups("unsupported").map { try Data(contentsOf: $0) } == [original])
        #expect(try saved().items.map(\.text) == ["From the future", "Now"])
        _ = store.add("Later")
        store.flush()
        #expect(backups("unsupported").count == 1)
    }

    @Test func `a file that can't be read is never saved over, and comes first once it can be`() throws {
        try write([StashItem(text: "On disk", createdAt: .now)])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path())
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path()) }

        let store = StashStore(fileURL: file, deleteDoneAfter: nil)
        #expect(store.hasSaveFailed && store.list.items.isEmpty)
        _ = store.add("In memory")
        store.flush()
        #expect(store.hasSaveFailed)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path())
        store.flush()
        #expect(!store.hasSaveFailed)
        #expect(store.list.items.map(\.text) == ["On disk", "In memory"])
        #expect(try saved().items.map(\.text) == ["On disk", "In memory"])
    }
}
