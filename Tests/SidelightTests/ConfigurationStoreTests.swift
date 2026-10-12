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

    private var backups: [URL] { backups(prefix: "config.invalid-") }

    private func backups(prefix: String) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
        return (contents ?? []).filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    /// The default configuration as a file would have it, with its calendar showing `eventCount` events, written
    /// compactly and unsorted, as a hand edit might.
    private func file(eventCount: Int, windowAvoidance: WindowAvoidanceMode = .smart) throws -> Data {
        var configuration = AppConfiguration()
        configuration.windowAvoidance = windowAvoidance
        var file = try #require(try JSONSerialization.jsonObject(with: configuration.json()) as? [String: Any])
        var sections = try #require(file["sections"] as? [[String: Any]])
        var widgets = try #require(sections[0]["widgets"] as? [[String: Any]])
        let calendar = try #require(widgets.firstIndex { $0["kind"] as? String == "calendar" })
        widgets[calendar]["settings"] = ["eventCount": eventCount]
        sections[0]["widgets"] = widgets
        file["sections"] = sections
        return try JSONSerialization.data(withJSONObject: file)
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

    @Test func `keeps a file with a value moved into range before saving over it`() throws {
        let outOfRange = try file(eventCount: 900)
        try outOfRange.write(to: file)
        let store = ConfigurationStore(fileURL: file)
        #expect(try Data(contentsOf: file) == outOfRange)
        store.configuration.windowAvoidance = .off
        store.flush()
        #expect(try backups(prefix: "config.unsupported-").map { try Data(contentsOf: $0) } == [outOfRange])
        #expect(try AppConfiguration(json: Data(contentsOf: file)).windowAvoidance == .off)
        store.configuration.windowAvoidance = .smart
        store.flush()
        #expect(backups(prefix: "config.unsupported-").count == 1)
        #expect(backups.isEmpty)
    }

    @Test func `keeps an external edit with a value moved into range before saving over it`() async throws {
        let store = ConfigurationStore(fileURL: file)
        store.startWatchingFile()
        let outOfRange = try file(eventCount: 900)
        try outOfRange.write(to: file)
        try await Task.sleep(for: .milliseconds(500))
        #expect(store.configuration.widgets.contains { $0.settings == .calendar(CalendarSettings(eventCount: 10)) })
        store.configuration.windowAvoidance = .off
        store.flush()
        #expect(try backups(prefix: "config.unsupported-").map { try Data(contentsOf: $0) } == [outOfRange])
    }

    @Test func `keeps an edit not read yet with a value moved into range before saving over it`() throws {
        let store = ConfigurationStore(fileURL: file)
        let outOfRange = try file(eventCount: 900)
        try outOfRange.write(to: file)
        store.configuration.windowAvoidance = .off
        store.flush()
        #expect(try backups(prefix: "config.unsupported-").map { try Data(contentsOf: $0) } == [outOfRange])
        #expect(try AppConfiguration(json: Data(contentsOf: file)).windowAvoidance == .off)
    }

    @Test func `saves over an edit not read yet without a backup when nothing in it is lost`() throws {
        let store = ConfigurationStore(fileURL: file)
        try file(eventCount: 5).write(to: file)
        store.configuration.windowAvoidance = .off
        store.flush()
        #expect(backups(prefix: "config.unsupported-").isEmpty && backups.isEmpty)
        #expect(try AppConfiguration(json: Data(contentsOf: file)).windowAvoidance == .off)
    }

    @Test func `doesn't save over an edit with a value moved into range when it can't be kept`() throws {
        let store = ConfigurationStore(fileURL: file)
        // Every name a backup could take in the next few seconds is already used.
        for offset in -2...10 {
            let stamp = Date.now.addingTimeInterval(Double(offset))
                .formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacing(":", with: "-")
            for attempt in 1...20 {
                let name = attempt == 1 ? "unsupported-\(stamp)" : "unsupported-\(stamp)-\(attempt)"
                try Data().write(to: file.deletingPathExtension().appendingPathExtension("\(name).json"))
            }
        }
        let outOfRange = try file(eventCount: 900)
        try outOfRange.write(to: file)
        store.configuration.windowAvoidance = .off
        store.flush()
        #expect(try Data(contentsOf: file) == outOfRange)
    }

    @Test func `saves over a file it keeps everything of without a backup`() throws {
        try file(eventCount: 5, windowAvoidance: .off).write(to: file)
        let store = ConfigurationStore(fileURL: file)
        store.configuration.windowAvoidance = .smart
        store.flush()
        #expect(backups(prefix: "config.unsupported-").isEmpty && backups.isEmpty)
        #expect(try AppConfiguration(json: Data(contentsOf: file)).windowAvoidance == .smart)
    }

    @Test func `flushes a pending change right away`() throws {
        let store = ConfigurationStore(fileURL: file)
        store.configuration.windowAvoidance = .off
        store.flush()
        #expect(try AppConfiguration(json: Data(contentsOf: file)).windowAvoidance == .off)
    }
}
