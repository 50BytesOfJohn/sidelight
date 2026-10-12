import Foundation
import Testing

@testable import Sidelight
@testable import SidelightCore

struct ConfigurationStoreTests {
    let directory = URL.temporaryDirectory.appending(path: "sidelight-store-\(UUID().uuidString)")
    var file: URL { directory.appending(path: "config.json") }

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var backups: [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
        return (contents ?? []).filter { $0.lastPathComponent.hasPrefix("config.invalid-") }
    }

    @Test func `writes defaults when there's no file yet`() throws {
        let store = ConfigurationStore(fileURL: file)
        #expect(store.configuration.widgets.map(\.kind) == AppConfiguration.defaultWidgets.map(\.kind))
        #expect(try AppConfiguration(json: Data(contentsOf: file)) == store.configuration)
    }

    @Test func `keeps an unreadable file before replacing it`() throws {
        let broken = Data("{ not json".utf8)
        try broken.write(to: file)
        let store = ConfigurationStore(fileURL: file)
        #expect(backups.count == 1)
        #expect(try backups.first.map { try Data(contentsOf: $0) } == broken)
        #expect(try AppConfiguration(json: Data(contentsOf: file)) == store.configuration)
    }

    @Test func `never replaces an earlier backup, even from the same second`() throws {
        try Data("first".utf8).write(to: file)
        _ = ConfigurationStore(fileURL: file)
        try Data("second".utf8).write(to: file)
        _ = ConfigurationStore(fileURL: file)
        let kept = try Set(backups.map { try String(decoding: Data(contentsOf: $0), as: UTF8.self) })
        #expect(kept == ["first", "second"])
    }

    @Test(arguments: [false, true])
    func `keeps an invalid edit before saving a change over it`(waitsForTheWatcher: Bool) async throws {
        let store = ConfigurationStore(fileURL: file)
        store.startWatchingFile()
        let edit = Data(#"{ "windowAvoidance": "#.utf8)
        try edit.write(to: file)
        // Read and ignored, or not read yet: either way it's kept.
        if waitsForTheWatcher { try await Task.sleep(for: .milliseconds(500)) }
        #expect(backups.isEmpty)
        store.configuration.windowAvoidance = .off
        store.flush()
        #expect(try backups.map { try Data(contentsOf: $0) } == [edit])
        #expect(try AppConfiguration(json: Data(contentsOf: file)).windowAvoidance == .off)
    }

    @Test func `flushes a pending change right away`() throws {
        let store = ConfigurationStore(fileURL: file)
        store.configuration.windowAvoidance = .off
        store.flush()
        #expect(try AppConfiguration(json: Data(contentsOf: file)).windowAvoidance == .off)
    }
}
