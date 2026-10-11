import Foundation
import SQLite3
import Testing

@testable import SidelightCore

/// Only fabricated metadata; no provider home, auth data or session body is needed by these tests.
private final class ChatDatabase {
    let directory: URL
    let url: URL
    var connection: OpaquePointer?

    init(
        schema: String =
            "composerId TEXT, value BLOB, lastUpdatedAt INTEGER, createdAt INTEGER, isArchived INTEGER, isSubagent INTEGER"
    ) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        url = directory.appending(path: "state.vscdb")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(sqlite3_open(url.path, &connection) == SQLITE_OK)
        try execute("CREATE TABLE composerHeaders (\(schema))")
    }

    deinit {
        sqlite3_close(connection)
        try? FileManager.default.removeItem(at: directory)
    }

    func execute(_ sql: String) throws {
        let result = sqlite3_exec(connection, sql, nil, nil, nil)
        try #require(result == SQLITE_OK, "Fixture SQL failed: \(String(cString: sqlite3_errmsg(connection)))")
    }

    func insert(
        _ id: String, header: String = "{}", updated: String = "1800000000000", created: String = "NULL",
        archived: Int = 0, subagent: Int = 0
    ) throws {
        let escaped = header.replacingOccurrences(of: "'", with: "''")
        try execute(
            "INSERT INTO composerHeaders VALUES ('\(id)', '\(escaped)', \(updated), \(created), \(archived), \(subagent))"
        )
    }

    func chats(since: Date = Date(timeIntervalSince1970: 0), limit: Int = 200) throws -> [CursorChat] {
        try CursorChatIndex.chats(updatedSince: since, limit: limit, in: url).get()
    }
}

struct CursorChatIndexTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `current headers supply clean titles local projects and millisecond times`() throws {
        let db = try ChatDatabase()
        try db.insert(
            "a",
            header:
                #"{"name":"  Demo\n   chat  ","workspaceIdentifier":{"uri":{"scheme":"file","fsPath":"/tmp/Demo Project"}},"status":"generating"}"#,
            created: "1799999999000")
        let chat = try #require(try db.chats().first)
        #expect(chat.name == "Demo chat")
        #expect(chat.project == "Demo Project")
        #expect(chat.createdAt == now.addingTimeInterval(-1))
        #expect(chat.updatedAt == now)
        #expect(AgentSession(chat).status == .untracked)
    }

    @Test func `optional columns and future metadata do not break supported schema`() throws {
        let db = try ChatDatabase(schema: "composerId TEXT, value BLOB, lastUpdatedAt INTEGER")
        try db.execute(
            #"INSERT INTO composerHeaders VALUES ('a', '{"name":42,"future":{"x":1},"workspaceIdentifier":{"uri":{"scheme":"ssh","fsPath":"/remote/demo"}}}', 1800000000000)"#
        )
        let chat = try #require(try db.chats().first)
        #expect(chat.name == nil)
        #expect(chat.workspacePath == nil)
        #expect(chat.createdAt == nil)
        #expect(chat.updatedAt == now)
    }

    @Test func `one partial corrupt or null header cannot discard its valid neighbors`() throws {
        let db = try ChatDatabase()
        try db.insert("good", header: #"{"name":"Valid"}"#)
        try db.insert("partial", header: #"{"name":"Cut"#)
        try db.insert("wrong", header: "[]")
        try db.insert("", header: "{}")
        try db.execute("INSERT INTO composerHeaders VALUES ('null', NULL, 1800000000000, NULL, 0, 0)")
        #expect(try db.chats().map(\.id) == ["good"])
    }

    @Test(arguments: ["isArchived", "isSubagent", "isDraft", "isEphemeral"])
    func `hidden metadata records are excluded`(flag: String) throws {
        let db = try ChatDatabase()
        try db.insert("hidden", header: "{\"\(flag)\":true}")
        try db.insert("visible", header: "{\"\(flag)\":false}")
        #expect(try db.chats().map(\.id) == ["visible"])
    }

    @Test func `archived and subagent columns exclude records even with clean JSON`() throws {
        let db = try ChatDatabase()
        try db.insert("archived", archived: 1)
        try db.insert("subagent", subagent: 1)
        try db.insert("visible")
        #expect(try db.chats().map(\.id) == ["visible"])
    }

    @Test func `cutoff is inclusive newest rows win and the input query is bounded`() throws {
        let db = try ChatDatabase()
        try db.execute(
            "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<1000) INSERT INTO composerHeaders SELECT 'row-'||x, '{}', 1800000000000+x, NULL, 0, 0 FROM n"
        )
        let rows = try db.chats(limit: 7)
        #expect(rows.count == 7)
        #expect(rows.first?.id == "row-1000")
        #expect(rows.last?.id == "row-994")
        #expect(try db.chats(limit: 0).isEmpty)
        #expect(try db.chats(since: now.addingTimeInterval(1)).map(\.id) == ["row-1000"])
        #expect(try db.chats(since: now.addingTimeInterval(1.001)).isEmpty)
    }

    @Test func `nullable updated time falls back to created time without reading body tables`() throws {
        let db = try ChatDatabase()
        try db.insert(
            "created", header: #"{"name":"Metadata only","createdAt":"1800000000000"}"#,
            updated: "NULL", created: "1800000000000")
        // Deliberately invalid private payloads: a metadata reader should not decode them.
        try db.execute("CREATE TABLE cursorDiskKV (key TEXT, value BLOB)")
        try db.execute("INSERT INTO cursorDiskKV VALUES ('composerData:created', x'000102ff')")
        try db.execute("CREATE TABLE ItemTable (key TEXT, value BLOB)")
        try db.execute("INSERT INTO ItemTable VALUES ('auth-placeholder', x'ff')")
        let before = try Data(contentsOf: db.url)
        let chats = try db.chats(since: now)
        #expect(chats.first?.updatedAt == now)
        #expect(chats.first?.createdAt == now)
        #expect(try Data(contentsOf: db.url) == before)
        #expect(!FileManager.default.fileExists(atPath: db.url.path + "-journal"))
    }

    @Test func `missing corrupt and unsupported databases have distinct outcomes`() throws {
        let db = try ChatDatabase(schema: "composerId TEXT, value BLOB")
        if case .failure(.unsupported) = CursorChatIndex.chats(updatedSince: now, in: db.url) {
        } else {
            Issue.record("Missing required columns must be unsupported")
        }
        let missing = db.directory.appending(path: "missing.vscdb")
        if case .failure(.noDatabase) = CursorChatIndex.chats(updatedSince: now, in: missing) {
        } else {
            Issue.record("A missing database must be noDatabase")
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        let corrupt = db.directory.appending(path: "corrupt.vscdb")
        try Data("not sqlite".utf8).write(to: corrupt)
        if case .failure(.unreadable) = CursorChatIndex.chats(updatedSince: now, in: corrupt) {
        } else {
            Issue.record("Corruption must be unreadable, not an unsupported schema")
        }
    }

    @Test func `legacy global index alone is explicitly unsupported`() throws {
        let db = try ChatDatabase()
        try db.execute("DROP TABLE composerHeaders")
        try db.execute("CREATE TABLE ItemTable (key TEXT, value TEXT)")
        try db.execute("INSERT INTO ItemTable VALUES ('composer.composerData', '{}')")
        if case .failure(.unsupported) = CursorChatIndex.chats(updatedSince: now, in: db.url) {
        } else {
            Issue.record("Legacy schema must not be mistaken for an empty supported list")
        }
    }

    @Test func `invalid timestamp type cannot become a fabricated epoch date`() throws {
        let db = try ChatDatabase()
        try db.insert("invalid", updated: "'not-a-time'")
        #expect(try db.chats().isEmpty)
    }

    @Test(arguments: ["'1800000000000'", "1800000000000.0"])
    func `numeric SQLite timestamp representations preserve millisecond date`(value: String) throws {
        let db = try ChatDatabase()
        try db.insert("numeric", updated: value)
        #expect(try db.chats().first?.updatedAt == now)
    }

    @Test func `project extraction has no root or empty project and preserves spaces`() {
        #expect(CursorChat(id: "a", workspacePath: "/", updatedAt: now).project == nil)
        #expect(CursorChat(id: "a", workspacePath: "", updatedAt: now).project == nil)
        #expect(CursorChat(id: "a", workspacePath: "/tmp/Demo Project/", updatedAt: now).project == "Demo Project")
    }
}

struct CursorPostFixTests {
    private let boundary = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: ["1800000000000", "1800000000000.0", "'1800000000000'"])
    func storageTypesAreActuallyDistinct(value: String) throws {
        let db = try ChatDatabase(schema: "composerId, value, lastUpdatedAt, createdAt, isArchived, isSubagent")
        try db.insert("boundary", updated: value)
        try db.insert("before", updated: "1799999999999")
        try db.insert("after", updated: "1800000000001")
        let rows = try db.chats(since: boundary)
        #expect(rows.map(\.id) == ["after", "boundary"])
        #expect(rows.last?.updatedAt == boundary)
        // Decode the fixture's Unix milliseconds for the exact inclusive boundary. Adding 1 ms to
        // Date's reference-epoch storage rounds differently and lands just after this row's Date.
        let upperBoundary = Date(timeIntervalSince1970: 1_800_000_000_001.0 / 1000)
        let upperRows = try db.chats(since: upperBoundary)
        #expect(upperRows.map(\.id) == ["after"])
        #expect(upperRows.first?.updatedAt == upperBoundary)

        let between = Date(timeIntervalSince1970: 1_800_000_000_000.5 / 1000)
        #expect(boundary < between && between < upperBoundary)
        let betweenRows = try db.chats(since: between)
        #expect(betweenRows.map(\.id) == ["after"])
        #expect(betweenRows.allSatisfy { $0.updatedAt >= between })

        // Keep the old arithmetic cutoff as an exclusion regression instead of falsely including an earlier Date.
        let roundedArithmeticCutoff = boundary.addingTimeInterval(0.001)
        #expect(roundedArithmeticCutoff > upperBoundary)
        #expect(try db.chats(since: roundedArithmeticCutoff).isEmpty)
    }

    @Test(arguments: [
        "'not-a-time'", "''", "'1800000000000oops'", "' 1800000000000'", "'1800000000000.0'",
        "x'31383030303030303030303030'", "NULL",
    ])
    func invalidStorageUsesOnlyValidatedCreatedColumn(value: String) throws {
        let db = try ChatDatabase(schema: "composerId, value, lastUpdatedAt, createdAt, isArchived, isSubagent")
        try db.insert("invalid", header: #"{"createdAt":1800000000000}"#, updated: value)
        try db.insert("fallback-before", updated: value, created: "1799999999999")
        try db.insert("fallback-boundary", updated: value, created: "'1800000000000'")
        try db.insert("fallback-after", updated: value, created: "1800000000001.0")
        #expect(try db.chats(since: boundary).map(\.id) == ["fallback-after", "fallback-boundary"])
        let rows = try db.chats()
        #expect(rows.map(\.id) == ["fallback-after", "fallback-boundary", "fallback-before"])
        #expect(rows.allSatisfy { $0.updatedAt.timeIntervalSince1970 > 0 })
        #expect(rows.last?.updatedAt == Date(timeIntervalSince1970: 1_799_999_999_999.0 / 1000))
    }

    @Test func busySchemaIsUnreadableAndUnlockRecovers() throws {
        let db = try ChatDatabase()
        try db.insert("good")
        try db.execute("BEGIN EXCLUSIVE")
        if case .failure(.unreadable) = CursorChatIndex.chats(updatedSince: boundary, in: db.url) {
        } else {
            Issue.record("Locked schema must be unreadable, not incompatible")
        }
        try db.execute("ROLLBACK")
        #expect(try db.chats().map(\.id) == ["good"])
    }

    @Test func malformedSchemaPrepareFailureIsUnreadable() throws {
        let db = try ChatDatabase()
        let original = try Data(contentsOf: db.url)
        sqlite3_close(db.connection)
        db.connection = nil
        var corrupted = original
        let needle = Data("CREATE TABLE composerHeaders".utf8)
        let range = try #require(corrupted.range(of: needle))
        corrupted.replaceSubrange(range, with: Data("CRATEE TABLE composerHeaders".utf8))
        try corrupted.write(to: db.url)
        if case .failure(.unreadable) = CursorChatIndex.chats(updatedSince: boundary, in: db.url) {
        } else {
            Issue.record("Malformed schema must be unreadable")
        }
        sqlite3_close(db.connection)
        db.connection = nil
        try original.write(to: db.url)
        #expect(try db.chats().isEmpty)
    }
    @Test func queryStepFailureIsUnreadableRatherThanEmptyOrUnsupported() throws {
        let db = try ChatDatabase()
        try db.execute("DROP TABLE composerHeaders")
        try db.execute(
            "CREATE VIEW composerHeaders AS SELECT 'synthetic' AS composerId, '{}' AS value, abs(-9223372036854775808) AS lastUpdatedAt"
        )
        if case .failure(.unreadable) = CursorChatIndex.chats(updatedSince: boundary, in: db.url) {
        } else {
            Issue.record("An evaluable schema with a failing query step must be unreadable")
        }
    }

    @Test func fractionalRealCutoffAndReturnedTimeAgree() throws {
        let db = try ChatDatabase(schema: "composerId, value, lastUpdatedAt, createdAt, isArchived, isSubagent")
        try db.insert("before", updated: "1800000000000.0")
        try db.insert("boundary", updated: "1800000000000.5")
        try db.insert("after", updated: "1800000000001.0")
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000_000.5 / 1000)
        let rows = try db.chats(since: cutoff)
        #expect(rows.map(\.id) == ["after", "boundary"])
        #expect(rows.allSatisfy { $0.updatedAt >= cutoff })
        #expect(rows.last?.updatedAt == cutoff)
    }

    @Test func actualEpochIsValidButInvalidStorageCannotInventIt() throws {
        let db = try ChatDatabase(schema: "composerId, value, lastUpdatedAt, createdAt, isArchived, isSubagent")
        try db.insert("integer-zero", updated: "0")
        try db.insert("text-zero", updated: "'0'")
        try db.insert("real-zero", updated: "0.0")
        try db.insert("invalid", updated: "'not-time'")
        try db.insert("header-created", header: #"{"createdAt":1800000000000}"#, created: "'invalid'")
        let rows = try db.chats()
        #expect(Set(rows.map(\.id)) == ["integer-zero", "text-zero", "real-zero", "header-created"])
        #expect(rows.filter { $0.id != "header-created" }.allSatisfy { $0.updatedAt == Date(timeIntervalSince1970: 0) })
        #expect(rows.first?.createdAt == boundary)
    }

}

struct CursorFinalPrecisionTests {
    @Test(arguments: [
        0.0, -0.000001, -0.001, -1.0, -86_400.0, -1_000_000_000.0, 978_307_200.0, 1_800_000_000.0005,
        1_800_000_000.123456,
    ])
    func cutoffMatchesActualDateConversion(seconds: Double) throws {
        let db = try ChatDatabase(schema: "composerId, value, lastUpdatedAt, createdAt, isArchived, isSubagent")
        let cutoff = Date(timeIntervalSince1970: seconds)
        let center = cutoff.timeIntervalSince1970 * 1000
        var times = Set([center, center.nextDown, center.nextUp])
        for delta in [-0.001, -0.00005, -0.000001, 0.000001, 0.00005, 0.001] {
            times.insert(center + delta)
        }
        let sorted = times.sorted(by: >)
        for (index, milliseconds) in sorted.enumerated() {
            try db.insert("row-\(index)", updated: String(milliseconds))
        }
        // Oracle is the reader's public Date semantics, independent of its SQL-bound helper.
        let expected = sorted.enumerated().filter {
            Date(timeIntervalSince1970: $0.element / 1000) >= cutoff
        }.map { "row-\($0.offset)" }
        let rows = try db.chats(since: cutoff)
        #expect(rows.map(\.id) == expected)
        #expect(rows.allSatisfy { $0.updatedAt >= cutoff })
    }

    @Test func referenceDateCutoffsMatchActualReturnedDates() throws {
        var reference = Date(timeIntervalSince1970: 1_800_000_000.0005).timeIntervalSinceReferenceDate
        for _ in 0..<8 {
            let cutoff = Date(timeIntervalSinceReferenceDate: reference)
            let db = try ChatDatabase(schema: "composerId, value, lastUpdatedAt, createdAt, isArchived, isSubagent")
            let center = cutoff.timeIntervalSince1970 * 1000
            let times = [center.nextDown.nextDown, center.nextDown, center, center.nextUp, center.nextUp.nextUp].sorted(
                by: >)
            for (index, milliseconds) in times.enumerated() {
                try db.insert("row-\(index)", updated: String(milliseconds))
            }
            let expected = times.enumerated().filter {
                Date(timeIntervalSince1970: $0.element / 1000) >= cutoff
            }.map { "row-\($0.offset)" }
            let rows = try db.chats(since: cutoff)
            #expect(rows.map(\.id) == expected, "Reference seconds: \(reference)")
            #expect(
                rows.allSatisfy { $0.updatedAt >= cutoff },
                "Reference cutoff: \(reference); returned reference times: \(rows.map { $0.updatedAt.timeIntervalSinceReferenceDate })"
            )
            reference = reference.nextUp
        }
    }

    @Test func nonfiniteCutoffsCompleteWithoutTraps() throws {
        let db = try ChatDatabase(schema: "composerId, value, lastUpdatedAt, createdAt, isArchived, isSubagent")
        try db.insert("finite", updated: "1800000000000.5")
        for seconds in [Double.nan, .infinity, .greatestFiniteMagnitude] {
            #expect(try db.chats(since: Date(timeIntervalSince1970: seconds)).isEmpty)
        }
        for seconds in [-Double.infinity, -Double.greatestFiniteMagnitude] {
            #expect(try db.chats(since: Date(timeIntervalSince1970: seconds)).map(\.id) == ["finite"])
        }
    }
}
