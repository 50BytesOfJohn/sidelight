import Foundation
import SQLite3
import SidelightCore

// Compile alongside the actual CursorChatsService source; only its scratch-home data is controlled here.
@main
struct ServiceHarness {
    static func main() async throws {
        let database = CursorChatsService.database
        let home = URL.homeDirectory.path
        guard home.contains("/build/agent-sessions-service-home") else { fatalError("Scratch test home required") }
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        guard sqlite3_open(database.path, &connection) == SQLITE_OK else { fatalError("Fixture DB open failed") }
        defer { sqlite3_close(connection) }
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        let sql =
            "CREATE TABLE composerHeaders (composerId TEXT, value BLOB, lastUpdatedAt INTEGER); INSERT INTO composerHeaders VALUES ('fixture', '{\"name\":\"Fixture before stop\"}', \(now))"
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { fatalError("Fixture SQL failed") }
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        func waitFor(_ condition: () -> Bool, seconds: Int = 3) async {
            for _ in 0..<(seconds * 20) {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        let cancelled = CursorChatsService()
        cancelled.start()
        cancelled.stop()
        await waitFor({ cancelled.hasLoaded }, seconds: 1)
        check("stop suppresses a pending initial result", !cancelled.hasLoaded && cancelled.chats.isEmpty)

        let service = CursorChatsService()
        service.start()
        service.start()
        await waitFor { service.hasLoaded }
        check("idempotent start reads metadata", service.chats.map(\.name) == ["Fixture before stop"])
        service.stop()
        service.stop()
        guard
            sqlite3_exec(
                connection, "UPDATE composerHeaders SET value='{\"name\":\"Fixture after stop\"}'", nil, nil, nil)
                == SQLITE_OK
        else { fatalError("Stopped-source write failed") }
        try await Task.sleep(for: .seconds(11))
        check(
            "stopped source does not publish filesystem changes", service.chats.map(\.name) == ["Fixture before stop"])
        service.start()
        await waitFor { service.chats.first?.name == "Fixture after stop" }
        check("restart reads changes made while stopped", service.chats.map(\.name) == ["Fixture after stop"])
        service.stop()

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: database.path)
        let unreadable = CursorChatsService()
        unreadable.start()
        await waitFor { unreadable.hasLoaded }
        check(
            "initial unreadable source is not presented as successfully found",
            unreadable.hasLoaded && unreadable.availability == .unreadable && unreadable.chats.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path)
        await waitFor({ unreadable.chats.first?.name == "Fixture after stop" }, seconds: 15)
        check(
            "readable metadata recovers after a filesystem event", unreadable.chats.first?.name == "Fixture after stop")
        unreadable.stop()
        sqlite3_close(connection)
        connection = nil
        let replacement = CursorChatsService()
        replacement.start()
        await waitFor { replacement.hasLoaded }
        let storage = database.deletingLastPathComponent()
        let oldStorage = storage.appendingPathExtension("old")
        try FileManager.default.moveItem(at: storage, to: oldStorage)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: oldStorage.appending(path: "state.vscdb"), to: database)
        var writer: OpaquePointer?
        guard sqlite3_open(database.path, &writer) == SQLITE_OK else { fatalError("Replacement open failed") }
        defer { sqlite3_close(writer) }
        guard
            sqlite3_exec(writer, "UPDATE composerHeaders SET value='{\"name\":\"Fixture replacement\"}'", nil, nil, nil)
                == SQLITE_OK
        else { fatalError("Replacement write failed") }
        await waitFor({ replacement.chats.first?.name == "Fixture replacement" }, seconds: 15)
        check("directory replacement reloads metadata", replacement.chats.first?.name == "Fixture replacement")
        guard
            sqlite3_exec(
                writer, "UPDATE composerHeaders SET value='{\"name\":\"Fixture second change\"}'", nil, nil, nil)
                == SQLITE_OK
        else { fatalError("Second write failed") }
        await waitFor({ replacement.chats.first?.name == "Fixture second change" }, seconds: 15)
        check(
            "watcher follows later writes after directory replacement",
            replacement.chats.first?.name == "Fixture second change")
        replacement.stop()
        sqlite3_close(writer)
        writer = nil
        let removedStorage = storage.appendingPathExtension("missing")
        try FileManager.default.moveItem(at: storage, to: removedStorage)
        let missing = CursorChatsService()
        missing.start()
        await waitFor { missing.hasLoaded }
        check("missing source is identified without a watcher", missing.availability == .notFound)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: removedStorage.appending(path: "state.vscdb"), to: database)
        await waitFor({ missing.chats.first?.name == "Fixture second change" }, seconds: 165)
        check(
            "120-second missing sweep discovers newly created storage",
            missing.chats.first?.name == "Fixture second change")
        missing.stop()
        print("RESULT 10 checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
