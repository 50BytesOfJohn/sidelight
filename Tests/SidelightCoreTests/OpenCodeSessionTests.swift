import Foundation
import SQLite3
import Testing

@testable import SidelightCore

/// Invented metadata only, never a provider's home or messages. The tagged native DDL is packaged under Tests/Fixtures.
private final class OpenCodeDatabase {
    let folder: URL
    let url: URL
    var writer: OpaquePointer?

    init(native: Bool = true) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        url = folder.appending(path: "opencode.db")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(sqlite3_open(url.path, &writer) == SQLITE_OK)
        if native {
            let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            try sql(
                String(
                    contentsOf: root.appending(path: "Tests/Fixtures/OpenCodeV2/v2.0.27-session-schema.sql"),
                    encoding: .utf8))
            try sql("DELETE FROM session_v2")
        }
    }

    deinit {
        sqlite3_close(writer)
        try? FileManager.default.removeItem(at: folder)
    }

    func sql(_ sql: String) throws {
        try #require(sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK, "Synthetic SQL failed")
    }

    func insert(_ id: String, time: String = "1800000000000", extras: String = "") throws {
        try sql(
            """
            INSERT INTO session_v2(id, project_id, slug, directory, version, time_created, time_updated)
            VALUES ('\(id)', 'prj_synthetic', 'fixture', '/synthetic/repo/src/api', '2.0.27', 1799999999000, \(time));
            \(extras)
            """)
    }

    func read(since: Date = .distantPast, limit: Int = 200) throws -> [OpenCodeSession] {
        try OpenCodeSessionIndex.sessions(updatedSince: since, limit: limit, in: url).get()
    }
}

struct OpenCodeIndexTests {
    @Test func nativeMetadataFiltersRootsChildrenArchivesAndKeepsForks() throws {
        let db = try OpenCodeDatabase()
        try db.insert(
            "ses_root",
            extras: """
                UPDATE session_v2 SET title='  Synthetic\n root\t title  ', path='src/api',
                time_idle=1800000005000, idle_outcome='succeeded', time_suspended=1800000006000;
                """)
        try db.insert("ses_child", extras: "UPDATE session_v2 SET parent_id='ses_root' WHERE id='ses_child'")
        try db.insert("ses_archived", extras: "UPDATE session_v2 SET time_archived=0 WHERE id='ses_archived'")
        try db.insert("ses_fork", extras: "UPDATE session_v2 SET fork_session_id='ses_root' WHERE id='ses_fork'")
        let rows = try db.read()
        #expect(rows.map(\.id) == ["ses_root", "ses_fork"])
        let root = try #require(rows.first)
        #expect(root.title == "Synthetic root title")
        #expect(root.directory == "/synthetic/repo/src/api")
        #expect(root.project == "repo")
        #expect(root.createdAt == Date(timeIntervalSince1970: 1_799_999_999))
        #expect(root.updatedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(rows.last?.title == nil)
        #expect(rows.last?.forkedFrom == "ses_root")
        let mapped = rows.map(AgentSession.init)
        #expect(
            mapped.allSatisfy {
                $0.status == .untracked && $0.isOpen == nil && !$0.status.isWorking && !$0.status.needsUser
                    && !$0.status.isOngoing
            })
        #expect(mapped.last?.title == "Untitled session")
        #expect(mapped.first?.surface == .other("OpenCode"))
        #expect(mapped.first?.cwd == root.directory)
        #expect(mapped.first?.since == root.updatedAt)
    }

    @Test func stableIdentityAcrossUpdatesAndAllFourProviders() {
        var source = OpenCodeSession(
            id: "shared", directory: "/synthetic/repo", createdAt: .distantPast, updatedAt: .now)
        let before = AgentSession(source)
        source.title = "Changed"
        source.updatedAt = .distantFuture
        let after = AgentSession(source)
        #expect(before.id == after.id)
        #expect(after.provider == .openCode)
        #expect(after.source == .openCode(source))
        let others = [
            AgentSession(CursorChat(id: "shared", updatedAt: .now)),
            AgentSession(CodexSession(id: "shared", title: "Fixture", activity: .idle, since: .now)),
            AgentSession(ClaudeSession(id: "shared", title: "Fixture", activity: .idle, since: .now)),
        ]
        #expect(Set((others + [before, after]).map(\.id)).count == 4)
    }

    @Test func orderingLimitsAndWindowAreDeterministic() throws {
        let db = try OpenCodeDatabase()
        for i in 0..<205 { try db.insert("ses_\(String(format: "%03d", i))") }
        try db.insert("ses_old", time: "1799913599999")
        try db.insert("ses_boundary", time: "1799913600000")
        try db.insert("ses_future", time: "1800000001000")
        let since = Date(timeIntervalSince1970: 1_799_913_600)
        #expect(try db.read(since: since).count == 200)
        #expect(try db.read(since: since, limit: 2).map(\.id) == ["ses_future", "ses_204"])
        #expect(try db.read(since: since, limit: 0).isEmpty)
        #expect(try db.read(since: since, limit: -1).isEmpty)
        let all = try db.read(since: since, limit: 500)
        #expect(all.last?.id == "ses_boundary")
        #expect(!all.contains { $0.id == "ses_old" })
    }

    @Test(arguments: [1_700_000_009_001, 1_800_000_000_123, 1_800_000_000_999, -1001])
    func exactDateBoundaryIncludesItsOwnStoredMillisecond(ms: Int64) throws {
        let db = try OpenCodeDatabase()
        try db.insert("ses_boundary", time: String(ms))
        let stored = try #require(try db.read().first).updatedAt
        #expect(try db.read(since: stored).map(\.id) == ["ses_boundary"])
        #expect(try db.read(since: stored.addingTimeInterval(0.0004)).isEmpty)
        #expect(try db.read(since: stored.addingTimeInterval(-0.0004)).count == 1)
    }

    @Test func malformedRowsDoNotBecomeInventedMetadata() throws {
        let db = try OpenCodeDatabase()
        try db.insert("ses_valid", extras: "UPDATE session_v2 SET title=' \n\t ', time_created='bad'")
        try db.insert("ses_text", time: "'not-a-time'")
        try db.insert("ses_real", time: "1800000000000.5")
        try db.insert("ses_blob", time: "X'0102'")
        try db.insert("ses_relative", extras: "UPDATE session_v2 SET directory='relative' WHERE id='ses_relative'")
        try db.insert("ses_integerdir", extras: "UPDATE session_v2 SET directory=X'0102' WHERE id='ses_integerdir'")
        try db.insert("", extras: "UPDATE session_v2 SET title=42 WHERE id=''")
        let rows = try db.read()
        #expect(rows.map(\.id) == ["ses_valid"])
        #expect(rows.first?.title == nil)
        #expect(rows.first?.createdAt == rows.first?.updatedAt)
    }

    @Test func rejectsV1EmptyPartialMissingDirectoriesAndCorruptionWithoutCreatingFiles() throws {
        let db = try OpenCodeDatabase(native: false)
        func failure(_ expected: OpenCodeSessionIndex.Failure) {
            switch OpenCodeSessionIndex.sessions(updatedSince: .distantPast, in: db.url) {
            case .failure(let actual): #expect(String(describing: actual) == String(describing: expected))
            case .success: Issue.record("Expected \(expected), accepted incompatible database")
            }
        }
        failure(.unsupported)
        try db.sql("CREATE TABLE session(id TEXT, time_updated INTEGER)")
        failure(.unsupported)
        try db.sql("CREATE TABLE session_v2(id TEXT, title TEXT, directory TEXT, time_updated INTEGER)")
        failure(.unsupported)
        sqlite3_close(db.writer)
        db.writer = nil
        try Data("not SQLite".utf8).write(to: db.url)
        failure(.unreadable)
        let missing = db.folder.appending(path: "missing.db")
        if case .failure(.noDatabase) = OpenCodeSessionIndex.sessions(updatedSince: .distantPast, in: missing) {
        } else {
            Issue.record("Missing DB classification")
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        if case .failure(.noDatabase) = OpenCodeSessionIndex.sessions(updatedSince: .distantPast, in: db.folder) {
        } else {
            Issue.record("Directory classification")
        }
    }

    @Test func minimalProjectionHandlesAbsentOptionalFieldsWithoutMessagesOrAuth() throws {
        let db = try OpenCodeDatabase(native: false)
        try db.sql(
            "CREATE TABLE session_v2(id TEXT, parent_id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER)"
        )
        try db.sql(
            "INSERT INTO session_v2 VALUES ('ses_minimal', NULL, '/synthetic/repo', NULL, 1800000000000, 1800000000000, NULL)"
        )
        let before = try Data(contentsOf: db.url)
        let rows = try db.read()
        #expect(rows.count == 1 && rows.first?.subpath == nil && rows.first?.forkedFrom == nil)
        #expect(try Data(contentsOf: db.url) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: db.folder.path).sorted() == ["opencode.db"])
    }

    @Test func readOnlyWALSeesCommittedRowsAndHasBoundedBusyFailure() throws {
        let db = try OpenCodeDatabase()
        try db.sql("PRAGMA journal_mode=WAL")
        try db.insert("ses_committed")
        let before = try Data(contentsOf: db.url)
        try db.sql("BEGIN IMMEDIATE")
        try db.insert("ses_uncommitted")
        #expect(try db.read().map(\.id) == ["ses_committed"])
        #expect(try Data(contentsOf: db.url) == before)
        try db.sql("COMMIT")
        #expect(try db.read().map(\.id) == ["ses_uncommitted", "ses_committed"])
        try db.sql("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE; BEGIN EXCLUSIVE")
        let start = ContinuousClock.now
        let result = OpenCodeSessionIndex.sessions(updatedSince: .distantPast, in: db.url)
        #expect(start.duration(to: .now) < .seconds(2))
        if case .failure(.unreadable) = result {} else { Issue.record("Exclusive lock must be unreadable") }
        try db.sql("ROLLBACK")
        #expect(try db.read().count == 2)
    }

    @Test(arguments: [
        ("/repo/src/api", "src/api", "repo"), ("/repo/src/api", "other", "api"), ("/repo", "", "repo"), ("/", "", nil),
    ])
    func projectNamesUseOnlyMatchingSubpaths(directory: String, subpath: String, expected: String?) {
        #expect(
            OpenCodeSession(id: "ses_x", directory: directory, subpath: subpath, createdAt: .now, updatedAt: .now)
                .project == expected)
    }
}

struct OpenCodeLocationAndLinksTests {
    @Test func databaseLocationsHonorOnlyGUIEnvironmentAndExactOverrides() {
        let home = URL(filePath: "/synthetic/home")
        let normal = OpenCodeSessionIndex.defaultDatabase(home: home)
        #expect(OpenCodeSessionIndex.location(environment: [:], home: home) == .file(normal))
        #expect(OpenCodeSessionIndex.location(environment: ["XDG_DATA_HOME": "relative"], home: home) == .file(normal))
        #expect(OpenCodeSessionIndex.location(environment: ["XDG_DATA_HOME": ""], home: home) == .file(normal))
        #expect(
            OpenCodeSessionIndex.location(environment: ["XDG_DATA_HOME": "/isolated data"], home: home)
                == .file(URL(filePath: "/isolated data/opencode/opencode.db")))
        #expect(
            OpenCodeSessionIndex.location(environment: ["OPENCODE_DB": "../alternate.db"], home: home)
                == .file(URL(filePath: "/synthetic/home/.local/share/alternate.db")))
        #expect(
            OpenCodeSessionIndex.location(
                environment: ["OPENCODE_DB": "/exact/store.db", "XDG_DATA_HOME": "/other"], home: home)
                == .file(URL(filePath: "/exact/store.db")))
        #expect(OpenCodeSessionIndex.location(environment: ["OPENCODE_DB": ""], home: home) == .dataFolder)
        #expect(OpenCodeSessionIndex.location(environment: ["OPENCODE_DB": ":memory:"], home: home) == .inMemory)
        #expect(
            OpenCodeSessionIndex.location(environment: ["OPENCODE_CONFIG_DIR": "/irrelevant"], home: home)
                == .file(normal))
    }

    // Command construction/validation was retired with the exact-resume feature.
    // ContractHarness replaces these four tests with no-route/no-dispatch and verbatim-copy coverage,
    // including all former unsafe ID/path inputs; metadata tests above remain unchanged.

}

struct OpenCodeConfigurationTests {
    @Test func releasedThreeProviderSelectionsStayExplicitAndNewWidgetsGetFour() throws {
        let old = Data(#"{"providers":["codex","claudeCode","cursor"],"sessionCount":5,"recentHours":24}"#.utf8)
        let settings = try JSONDecoder().decode(AgentSessionsSettings.self, from: old)
        #expect(settings.providers == [.codex, .claudeCode, .cursor])
        #expect(!settings.includes(.openCode))
        #expect(try JSONDecoder().decode(AgentSessionsSettings.self, from: JSONEncoder().encode(settings)) == settings)
        #expect(AgentSessionsSettings().providers == [.codex, .claudeCode, .cursor, .openCode])
        #expect(
            try JSONDecoder().decode(AgentSessionsSettings.self, from: Data("{}".utf8)).providers
                == AgentProvider.allCases)
        let future = try JSONDecoder().decode(
            AgentSessionsSettings.self,
            from: Data(#"{"providers":["openCode","future","openCode"],"recentHours":"wrong"}"#.utf8))
        #expect(future.providers == [.openCode] && future.recentHours == AgentSessionsSettings().recentHours)
    }

    @Test func openCodeDemandIsSharedVisibleAndReleasedByRemoval() {
        var widget = WidgetInstance(settings: .agentSessions(AgentSessionsSettings(providers: [.openCode])))
        var config = AppConfiguration()
        config.sections = [
            PanelSection(widgets: [
                widget, widget.duplicated(), WidgetInstance(kind: .codexSessions),
                WidgetInstance(kind: .claudeSessions),
            ])
        ]
        #expect(config.serviceDemand(at: [.left, .right]).sessions == [.openCode, .codex, .claudeCode])
        #expect(config.serviceDemand(at: [.left]).usage.providers.isEmpty)
        widget.showsInSidePanel = false
        widget.showsInBar = false
        config.sections = [PanelSection(widgets: [widget])]
        #expect(config.serviceDemand(at: [.left, .top]).sessions.isEmpty)
        #expect(config.serviceDemand(at: [], previewsEveryWidget: true).sessions == Set(AgentProvider.allCases))
        config.sections = []
        #expect(config.serviceDemand(at: [.left]).sessions.isEmpty)
    }
}
