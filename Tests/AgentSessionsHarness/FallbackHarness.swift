import CoreServices
import Foundation
import SQLite3
import SidelightCore
import Synchronization

// The Boolean return of the C Start boundary is injected; allocation/context ownership and
// invalidation/release use the real CoreServices API. No OS restriction is bypassed.
nonisolated enum StartBoundary {
    struct State: Sendable {
        var result = false
        var actual = false
        var calls: [String] = []
    }
    static let state = Mutex(State())
    static func start(_ stream: FSEventStreamRef) -> Bool {
        let actual = state.withLock { $0.actual }
        let result = actual ? FSEventStreamStart(stream) : state.withLock { $0.result }
        state.withLock { $0.calls.append("start") }
        return result
    }
    static func stop(_ stream: FSEventStreamRef) {
        state.withLock { $0.calls.append("stop") }
        FSEventStreamStop(stream)
    }
    static func invalidate(_ stream: FSEventStreamRef) {
        state.withLock { $0.calls.append("invalidate") }
        FSEventStreamInvalidate(stream)
    }
    static func release(_ stream: FSEventStreamRef) {
        state.withLock { $0.calls.append("release") }
        FSEventStreamRelease(stream)
    }
}

nonisolated final class CallbackOwner: Sendable {
    func called() {}
}

@main
struct FallbackHarness {
    static func main() async throws {
        guard URL.homeDirectory.path.contains("/build/opencode-testing/") else {
            fatalError("Fresh synthetic home required")
        }
        var checks = 0
        var failures = 0
        func check(_ name: String, _ valid: Bool) {
            checks += 1
            failures += valid ? 0 : 1
            print("\(valid ? "PASS" : "FAIL") \(name)")
        }
        func waitFor(_ condition: () -> Bool, seconds: Int = 4) async {
            for _ in 0..<(seconds * 10) {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let folder = URL.homeDirectory.appending(path: "boundary")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var owner: CallbackOwner? = CallbackOwner()
        weak var weakOwner = owner
        var failed: BoundaryFileEventStream? = BoundaryFileEventStream(
            directory: folder, latency: 10, queue: .main, handler: { [captured = owner!] in captured.called() })
        owner = nil
        check("actual wrapper init returns nil after injected Start false", failed == nil)
        check(
            "failed start invalidates then releases once without Stop",
            StartBoundary.state.withLock { $0.calls } == ["start", "invalidate", "release"])
        await waitFor { weakOwner == nil }
        check("real C release drops callback closure ownership on failed init", weakOwner == nil)
        failed = nil
        check("failed init never runs successful deinit", StartBoundary.state.withLock { $0.calls.count } == 3)

        StartBoundary.state.withLock {
            $0.result = true
            $0.calls = []
        }
        owner = CallbackOwner()
        weakOwner = owner
        var success: BoundaryFileEventStream? = BoundaryFileEventStream(
            directory: folder, latency: 10, queue: .main, handler: { [captured = owner!] in captured.called() })
        owner = nil
        check("injected success retains callback while wrapper lives", success != nil && weakOwner != nil)
        success = nil
        check(
            "success deinit still stops invalidates releases once",
            StartBoundary.state.withLock { $0.calls } == ["start", "stop", "invalidate", "release"])
        await waitFor { weakOwner == nil }
        check("success deinit releases callback closure ownership", weakOwner == nil)
        StartBoundary.state.withLock {
            $0.result = false
            $0.calls = []
        }

        if CommandLine.arguments.contains("--lifecycle-only") {
            print("RESULT \(checks) checks, \(failures) failures; wrapper lifecycle only")
            if failures != 0 { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--actual-fallback") {
            StartBoundary.state.withLock { $0.actual = true }
            print("FALLBACK_MODE actual FSEventStreamStart result, no injection")
        }
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        func setup(_ url: URL, _ sql: String) throws -> OpaquePointer {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var connection: OpaquePointer?
            precondition(sqlite3_open(url.path, &connection) == SQLITE_OK)
            precondition(sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK)
            return connection!
        }
        let openWriter = try setup(
            OpenCodeSessionsService.database!,
            "CREATE TABLE session_v2(id TEXT, parent_id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER); INSERT INTO session_v2 VALUES ('ses_fixture',NULL,'/synthetic/repo','Initial',\(now),\(now),NULL)"
        )
        let cursorWriter = try setup(
            CursorChatsService.database,
            "CREATE TABLE composerHeaders(composerId TEXT,value BLOB,lastUpdatedAt INTEGER); INSERT INTO composerHeaders VALUES ('synthetic','{\"name\":\"Initial\"}',\(now))"
        )
        defer {
            sqlite3_close(openWriter)
            sqlite3_close(cursorWriter)
        }
        let openCode = OpenCodeSessionsService()
        let cursor = CursorChatsService()
        openCode.start()
        cursor.start()
        await waitFor { openCode.hasLoaded && cursor.hasLoaded }
        check(
            "OpenCode successful initial read with unavailable watcher keeps sweep",
            openCode.sessions.first?.title == "Initial" && openCode.availability == .found && openCode.watcher == nil
                && openCode.sweepTask != nil)
        check(
            "Cursor successful initial read with unavailable watcher keeps sweep",
            cursor.chats.first?.name == "Initial" && cursor.availability == .found && cursor.watcher == nil
                && cursor.sweepTask != nil)
        precondition(sqlite3_exec(openWriter, "UPDATE session_v2 SET title='Swept'", nil, nil, nil) == SQLITE_OK)
        precondition(
            sqlite3_exec(cursorWriter, "UPDATE composerHeaders SET value='{\"name\":\"Swept\"}'", nil, nil, nil)
                == SQLITE_OK)
        let started = ContinuousClock.now
        await waitFor(
            { openCode.sessions.first?.title == "Swept" && cursor.chats.first?.name == "Swept" }, seconds: 165)
        print("REAL_SWEEP_ELAPSED \(started.duration(to: .now))")
        check(
            "OpenCode real 120s fallback reads later write and remains active",
            openCode.sessions.first?.title == "Swept" && openCode.sweepTask != nil && openCode.watcher == nil)
        check(
            "Cursor real 120s fallback reads later write and remains active",
            cursor.chats.first?.name == "Swept" && cursor.sweepTask != nil && cursor.watcher == nil)
        check(
            "fallback retries failed wrapper startup",
            StartBoundary.state.withLock { $0.calls.filter { $0 == "start" }.count } >= 4)
        openCode.stop()
        cursor.stop()
        check(
            "both stops cancel fallback ownership",
            openCode.sweepTask == nil && cursor.sweepTask == nil && openCode.reloadTask == nil
                && cursor.reloadTask == nil)
        print(
            "RESULT \(checks) checks, \(failures) failures; injected C start, actual C ownership/readers/services/timers"
        )
        if failures != 0 { exit(1) }
    }
}
