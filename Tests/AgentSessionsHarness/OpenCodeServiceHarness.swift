import Foundation
import SQLite3
import SidelightCore

// Actual service/reader/FSEvents. All paths are fabricated and rooted in the owned scratch home.
@main
struct OpenCodeServiceHarness {
    static func main() async throws {
        guard URL.homeDirectory.path.contains("/build/opencode-testing/"),
            let database = OpenCodeSessionsService.database
        else { fatalError("Synthetic file home required") }
        let storage = database.deletingLastPathComponent()
        var checks = 0
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            checks += 1
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        func waitFor(_ condition: () -> Bool, seconds: Int = 4) async {
            for _ in 0..<(seconds * 10) {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let service = OpenCodeSessionsService()
        service.start()
        service.start()
        await waitFor { service.hasLoaded }
        check(
            "missing folder classified without initializing vendor storage",
            service.hasLoaded && service.availability == .notFound
                && !FileManager.default.fileExists(atPath: database.path))
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        var writer: OpaquePointer?
        guard sqlite3_open(database.path, &writer) == SQLITE_OK else { fatalError("Synthetic DB") }
        defer { sqlite3_close(writer) }
        func sql(_ sql: String) {
            precondition(sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK)
        }
        sql(
            "CREATE TABLE session_v2(id TEXT, parent_id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER)"
        )
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        sql("INSERT INTO session_v2 VALUES ('ses_fixture', NULL, '/synthetic/repo', 'Initial', \(now), \(now), NULL)")
        await waitFor({ service.sessions.first?.title == "Initial" }, seconds: 165)
        check("real 120s missing sweep discovers new folder", service.sessions.first?.title == "Initial")
        sql("UPDATE session_v2 SET title='Changed'")
        await waitFor({ service.sessions.first?.title == "Changed" }, seconds: 25)
        check("real 10s FSEvent updates metadata", service.sessions.first?.title == "Changed")
        service.stop()
        service.stop()
        sql("UPDATE session_v2 SET title='Stopped'")
        try await Task.sleep(for: .seconds(12))
        check("stopped service does not publish writes", service.sessions.first?.title != "Stopped")
        service.start()
        await waitFor { service.sessions.first?.title == "Stopped" }
        check("restart reads stopped writes", service.sessions.first?.title == "Stopped")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: database.path)
        await waitFor({ service.availability == .unreadable }, seconds: 25)
        check(
            "unreadable event preserves stale metadata",
            service.availability == .unreadable && service.sessions.first?.title == "Stopped")
        service.stop()
        let initialError = OpenCodeSessionsService()
        initialError.start()
        await waitFor { initialError.hasLoaded }
        check(
            "first read error has no fabricated rows",
            initialError.availability == .unreadable && initialError.sessions.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path)
        sql("UPDATE session_v2 SET title='Recovered'")
        await waitFor({ initialError.sessions.first?.title == "Recovered" }, seconds: 25)
        check(
            "real event recovery clears read error",
            initialError.availability == .found && initialError.sessions.first?.title == "Recovered")
        initialError.stop()
        print("RESULT \(checks) checks, \(failures) failures; real source/service, no vendor dispatch")
        if failures != 0 { exit(1) }
    }
}
