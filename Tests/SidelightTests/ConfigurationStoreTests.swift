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

    /// Uses every name a backup for `reason` could take in the next few seconds, so keeping one fails.
    private func blockBackups(as reason: String) throws {
        for offset in -2...10 {
            let stamp = Date.now.addingTimeInterval(Double(offset))
                .formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacing(":", with: "-")
            for attempt in 1...20 {
                let name = attempt == 1 ? "\(reason)-\(stamp)" : "\(reason)-\(stamp)-\(attempt)"
                try Data().write(to: file.deletingPathExtension().appendingPathExtension("\(name).json"))
            }
        }
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
        if waitsForTheWatcher { await settle(.milliseconds(500)) }
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
        // However long the file event and the reload take on a busy machine.
        #expect(
            await eventually {
                store.configuration.widgets.contains { $0.settings == .calendar(CalendarSettings(eventCount: 10)) }
            })
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

    @Test func `keeps an edit not read yet before saving a change made in the app over it`() throws {
        let store = ConfigurationStore(fileURL: file)
        let edit = try file(eventCount: 5)
        try edit.write(to: file)
        store.configuration.windowAvoidance = .off
        store.flush()
        #expect(try backups(prefix: "config.external-edit-").map { try Data(contentsOf: $0) } == [edit])
        #expect(backups(prefix: "config.unsupported-").isEmpty && backups.isEmpty)
        #expect(try AppConfiguration(json: Data(contentsOf: file)) == store.configuration)
    }

    @Test func `saves over an edit not read yet without a backup when it loses nothing`() throws {
        try file(eventCount: 5).write(to: file)
        let store = ConfigurationStore(fileURL: file)
        // Only reformatted.
        let reformatted = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: Data(contentsOf: file)), options: .prettyPrinted)
        try reformatted.write(to: file)
        store.configuration.windowAvoidance = .off
        store.flush()
        // Already what the app saves.
        var configuration = store.configuration
        configuration.windowAvoidance = .smart
        try configuration.json().write(to: file)
        store.configuration = configuration
        store.flush()
        #expect(backups(prefix: "config.").filter { $0.lastPathComponent != "config.json" }.isEmpty)
    }

    @Test func `keeps an edit made while a change in the app waits to be saved`() async throws {
        let store = ConfigurationStore(fileURL: file)
        store.startWatchingFile()
        store.configuration.windowAvoidance = .off
        let edit = try file(eventCount: 5)
        try edit.write(to: file)
        // The reload runs first and saves the app's change, or the save runs first: either way both are kept.
        // The save keeps the edit aside before writing, so the file holding the app's change means both have landed.
        #expect(
            await eventually {
                (try? AppConfiguration(json: Data(contentsOf: file)).windowAvoidance) == .off
            })
        #expect(store.configuration.windowAvoidance == .off)
        #expect(try AppConfiguration(json: Data(contentsOf: file)).windowAvoidance == .off)
        #expect(try backups(prefix: "config.external-edit-").map { try Data(contentsOf: $0) } == [edit])
    }

    @Test func `doesn't save over an edit not read yet when it can't be kept`() throws {
        let store = ConfigurationStore(fileURL: file)
        try blockBackups(as: "external-edit")
        let edit = try file(eventCount: 5)
        try edit.write(to: file)
        store.configuration.windowAvoidance = .off
        store.flush()
        #expect(try Data(contentsOf: file) == edit)
    }

    @Test func `doesn't save over an edit with a value moved into range when it can't be kept`() throws {
        let store = ConfigurationStore(fileURL: file)
        try blockBackups(as: "unsupported")
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

    @Test func `a configuration from before accounts keeps every widget, with the old file kept aside once`() throws {
        var configuration = AppConfiguration()
        configuration.sections[0].widgets.append(WidgetInstance(settings: .railway(RailwaySettings())))
        var json = try #require(try JSONSerialization.jsonObject(with: configuration.json()) as? [String: Any])
        json["accounts"] = nil
        json["defaultAccounts"] = nil
        var sections = try #require(json["sections"] as? [[String: Any]])
        var widgets = try #require(sections[0]["widgets"] as? [[String: Any]])
        widgets[widgets.count - 1]["settings"] = ["account": "token"]
        sections[0]["widgets"] = widgets
        json["sections"] = sections
        let legacy = try JSONSerialization.data(withJSONObject: json)
        try legacy.write(to: file)

        let store = ConfigurationStore(fileURL: file)
        #expect(store.configuration.widgets.map(\.id) == configuration.widgets.map(\.id))
        guard case .railway(let railway) = store.configuration.widgets.last?.settings else {
            Issue.record("The Railway widget is gone")
            return
        }
        #expect(railway.account == nil)
        store.configuration.windowAvoidance = .off
        store.flush()
        #expect(backups(prefix: "config.unsupported-").count == 1)
        #expect(try backups(prefix: "config.unsupported-").first.map { try Data(contentsOf: $0) } == legacy)
        #expect(try AppConfiguration(json: Data(contentsOf: file)).widgets == store.configuration.widgets)
        store.configuration.windowAvoidance = .clip
        store.flush()
        #expect(backups(prefix: "config.unsupported-").count == 1)
    }
}
