import Foundation
import SQLite3
import Testing

@testable import SidelightCore

/// Answers shaped like OpenCode's Console endpoints, and credentials like OpenCode 2 stores them, with made-up values.
private enum Fixture {
    static let goUsage = #"""
        {"usage":{"rolling":{"status":"ok","percent":34,"resetsAt":"2026-10-27T18:00:00.000Z"},
                  "weekly":{"status":"ok","percent":61.5,"resetsAt":1793577600000},
                  "monthly":{"status":"rate-limited","percent":100,"resetsAt":"2026-11-27T09:12:00Z"}}}
        """#

    static let budgets = #"""
        [{"ruleID":"rule_all","limitDollars":20,"spentDollars":5,"scope":"combined","per":"set","coverage":"all",
          "models":[],"vendors":[],"picked":true,"shared":false,"resetsAt":"2026-11-01T00:00:00Z"},
         {"ruleID":"rule_models","limitDollars":10,"spentDollars":9,"scope":"each","per":"model",
          "coverage":"models","models":[{"providerID":"opencode","modelID":"glm-5.3","name":"GLM-5.3",
          "spentDollars":7.5},{"providerID":"opencode","modelID":"kimi-k3","name":"Kimi K3","spentDollars":1.5}],
          "vendors":[],"picked":false,"shared":false,"resetsAt":"2026-11-01T00:00:00Z"},
         {"ruleID":"broken"}]
        """#

    static let signIn = #"""
        {"type":"oauth","methodID":"device","access":"fake-access-token","refresh":"fake-refresh","expires":1795690176947,
         "metadata":{"server":"https://console.opencode.ai","accountID":"acc_FAKE","email":"me@example.com",
                     "orgID":"wrk_FAKE","orgName":"Default"}}
        """#

    static let goKey = #"{"type":"key","key":"sk-fake-go-key"}"#

    static let signedIn = OpenCodeCredential(stored: Data(signIn.utf8))!
}

struct OpenCodeUsageTests {
    @Test func `reads Go's three windows, with how long each lasts`() throws {
        let windows = try #require(OpenCodeUsage.goWindows(from: Data(Fixture.goUsage.utf8)))
        #expect(windows.map(\.kind) == [.rolling, .weekly, .monthly])
        #expect(windows[0].window.usedPercent == 34)
        #expect(windows[0].window.resetsAt == Date(iso8601: "2026-10-27T18:00:00Z"))
        #expect(windows[0].window.durationMinutes == 300)
        #expect(windows[1].window.resetsAt == Date(millisecondsSince1970: 1_793_577_600_000))
        #expect(windows[1].window.durationMinutes == 7 * 24 * 60)
        // October has 31 days.
        #expect(windows[2].window.durationMinutes == 31 * 24 * 60)
        #expect(windows.map(\.isLimited) == [false, false, true])
    }

    @Test func `answers without windows are nothing`() {
        for body in [#"{}"#, #"{"usage":{}}"#, #"{"usage":{"rolling":{"status":"ok"}}}"#, "nope"] {
            #expect(OpenCodeUsage.goWindows(from: Data(body.utf8)) == nil, "\(body)")
        }
    }

    @Test func `reads budgets, a per-model one by the model spending most, and skips broken ones`() throws {
        let budgets = try #require(OpenCodeUsage.budgets(from: Data(Fixture.budgets.utf8)))
        #expect(budgets.count == 2)
        #expect(budgets[0].usedPercent == 25)
        #expect(budgets[0].models.isEmpty)
        #expect(budgets[1].spent == 7.5)
        #expect(budgets[1].usedPercent == 75)
        #expect(budgets[1].models == ["GLM-5.3", "Kimi K3"])
    }
}

struct OpenCodeUsageAPITests {
    private let now = Date(timeIntervalSince1970: 1_793_100_000)

    @Test func `asks the Console as OpenCode does, for the sign-in's workspace`() throws {
        let go = OpenCodeUsageAPI.goUsageRequest(Fixture.signedIn, userAgent: "Sidelight/1.0")
        #expect(go.url?.absoluteString == "https://opencode.ai/zen/go/v1/usage")
        #expect(go.value(forHTTPHeaderField: "Authorization") == "Bearer fake-access-token")
        #expect(go.value(forHTTPHeaderField: "x-opencode-org-id") == "wrk_FAKE")
        #expect(!go.httpShouldHandleCookies)

        let budgets = OpenCodeUsageAPI.budgetsRequest(Fixture.signedIn, userAgent: "Sidelight/1.0")
        #expect(budgets.url?.absoluteString == "https://opencode.ai/console/api/policies/current-budgets")
        #expect(budgets.value(forHTTPHeaderField: "x-org-id") == "wrk_FAKE")
    }

    @Test func `a key names no workspace`() {
        let request = OpenCodeUsageAPI.goUsageRequest(.key("  sk-fake \n"), userAgent: "Sidelight/1.0")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-fake")
        #expect(request.value(forHTTPHeaderField: "x-opencode-org-id") == nil)
    }

    @Test func `reads Go and budgets together`() throws {
        let usage = try OpenCodeUsageAPI.result(
            go: .init(status: 200, body: Data(Fixture.goUsage.utf8)),
            budgets: .init(status: 200, body: Data(Fixture.budgets.utf8)), credential: Fixture.signedIn,
            receivedAt: now
        ).get()
        #expect(usage.go?.count == 3)
        #expect(usage.budgets.count == 2)
        #expect(usage.workspaceName == "Default")
        #expect(usage.isGoLimited)
        #expect(usage.fetchedAt == now)
    }

    @Test func `no Go subscription, and budgets that can't be read, still make usage`() throws {
        let usage = try OpenCodeUsageAPI.result(
            go: .init(status: 403, body: Data()), budgets: .init(status: 500, body: Data()),
            credential: Fixture.signedIn, receivedAt: now
        ).get()
        #expect(usage.go == nil)
        #expect(usage.budgets.isEmpty)
    }

    @Test func `rejections and unreadable answers are problems`() {
        let credential = Fixture.signedIn
        func result(_ status: Int, _ body: String = "") -> Result<OpenCodeUsage, OpenCodeFetchProblem> {
            OpenCodeUsageAPI.result(
                go: .init(status: status, body: Data(body.utf8)), budgets: nil, credential: credential,
                receivedAt: now)
        }
        #expect(result(401) == .failure(.rejected(status: 401)))
        #expect(result(429) == .failure(.rejected(status: 429)))
        #expect(result(200, "{}") == .failure(.unreadable))
        #expect(
            OpenCodeUsageAPI.result(go: nil, budgets: nil, credential: credential, receivedAt: now)
                == .failure(.unreachable))
        #expect(OpenCodeFetchProblem.rejected(status: 401).needsSignIn)
        #expect(OpenCodeFetchProblem.rejected(status: 401).accountStatus == .expired)
        #expect(!OpenCodeFetchProblem.rejected(status: 429).needsSignIn)
    }
}

struct OpenCodeCredentialTests {
    @Test func `reads OpenCode's sign-in, moving the Console to its new address`() throws {
        let credential = Fixture.signedIn
        #expect(credential.kind == .signIn)
        #expect(credential.token == "fake-access-token")
        #expect(credential.workspaceID == "wrk_FAKE")
        #expect(credential.console.absoluteString == "https://opencode.ai/console")
        #expect(credential.expiresAt == Date(millisecondsSince1970: 1_795_690_176_947))
        #expect(credential.identity == "me@example.com · Default")
        #expect(!credential.isExpired(at: Date(millisecondsSince1970: 1_795_690_176_946)))
        #expect(credential.isExpired(at: Date(millisecondsSince1970: 1_795_690_176_947)))
    }

    @Test func `reads a key, and nothing it can't use`() throws {
        let key = try #require(OpenCodeCredential(stored: Data(Fixture.goKey.utf8)))
        #expect(key.kind == .key)
        #expect(key.token == "sk-fake-go-key")
        #expect(key.workspaceID == nil)
        for stored in [#"{"type":"external"}"#, #"{"type":"oauth"}"#, #"{"type":"key","key":""}"#, "nope"] {
            #expect(OpenCodeCredential(stored: Data(stored.utf8)) == nil, "\(stored)")
        }
    }

    @Test func `only sends the token to an HTTPS Console`() throws {
        let stored = #"{"type":"oauth","access":"t","metadata":{"server":"http://example.com"}}"#
        let credential = try #require(OpenCodeCredential(stored: Data(stored.utf8)))
        #expect(credential.console == OpenCodeUsageAPI.defaultConsole)
    }

    @Test func `its description leaves the token out`() {
        #expect(!String(describing: Fixture.signedIn).contains("fake-access-token"))
    }
}

struct OpenCodeSignInTests {
    /// A database with OpenCode 2's `credential` table, holding `rows` of integration, value, active and when updated.
    private func makeDatabase(_ rows: [(String, String, Int, Int)], createsTable: Bool = true) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "sidelight-\(UUID().uuidString).db")
        var connection: OpaquePointer?
        try #require(sqlite3_open(url.path(percentEncoded: false), &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        let table = createsTable ? "credential" : "kv"
        let create = """
            CREATE TABLE \(table) (id TEXT PRIMARY KEY, integration_id TEXT, label TEXT NOT NULL, value TEXT NOT NULL,
            connector_id TEXT, method_id TEXT, active INTEGER, time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL)
            """
        try #require(sqlite3_exec(connection, create, nil, nil, nil) == SQLITE_OK)
        for (index, (integration, value, active, updated)) in rows.enumerated() {
            var statement: OpaquePointer?
            try #require(
                sqlite3_prepare_v2(
                    connection, "INSERT INTO credential VALUES (?, ?, 'Default', ?, NULL, NULL, ?, 0, ?)", -1,
                    &statement, nil) == SQLITE_OK)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, "cred_\(index)", -1, transient)
            sqlite3_bind_text(statement, 2, integration, -1, transient)
            sqlite3_bind_text(statement, 3, value, -1, transient)
            sqlite3_bind_int(statement, 4, Int32(active))
            sqlite3_bind_int(statement, 5, Int32(updated))
            try #require(sqlite3_step(statement) == SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        return url
    }

    private func credential(_ signIn: OpenCodeSignIn) -> OpenCodeCredential? {
        if case .signedIn(let credential) = signIn { credential } else { nil }
    }

    @Test func `reads OpenCode's active sign-in before Go's key`() throws {
        let other = #"{"type":"key","key":"sk-inactive"}"#
        let database = try makeDatabase([
            ("opencode-go", Fixture.goKey, 1, 3), ("opencode", other, 0, 2), ("opencode", Fixture.signIn, 1, 1),
            ("anthropic", #"{"type":"key","key":"sk-ant"}"#, 1, 4),
        ])
        defer { try? FileManager.default.removeItem(at: database) }
        #expect(credential(OpenCodeSignIn.read(database: database))?.token == "fake-access-token")
    }

    @Test func `Go's key stands in without an OpenCode sign-in`() throws {
        let database = try makeDatabase([("opencode-go", Fixture.goKey, 1, 1)])
        defer { try? FileManager.default.removeItem(at: database) }
        #expect(credential(OpenCodeSignIn.read(database: database))?.token == "sk-fake-go-key")
    }

    @Test func `no credential, no table or no database`() throws {
        let empty = try makeDatabase([("anthropic", #"{"type":"key","key":"sk-ant"}"#, 1, 1)])
        defer { try? FileManager.default.removeItem(at: empty) }
        guard case .signedOut = OpenCodeSignIn.read(database: empty) else {
            Issue.record("not signed out")
            return
        }

        let noTable = try makeDatabase([], createsTable: false)
        defer { try? FileManager.default.removeItem(at: noTable) }
        guard case .signedOut = OpenCodeSignIn.read(database: noTable) else {
            Issue.record("not signed out")
            return
        }

        let missing = FileManager.default.temporaryDirectory.appending(path: "sidelight-\(UUID().uuidString).db")
        guard case .notFound = OpenCodeSignIn.read(database: missing) else {
            Issue.record("found")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path(percentEncoded: false)))
    }
}

struct OpenCodeSummaryTests {
    private let now = Date(iso8601: "2026-10-27T15:00:00Z")!

    private var usage: OpenCodeUsage {
        get throws {
            try OpenCodeUsageAPI.result(
                go: .init(status: 200, body: Data(Fixture.goUsage.utf8)),
                budgets: .init(status: 200, body: Data(Fixture.budgets.utf8)), credential: Fixture.signedIn,
                receivedAt: now
            ).get()
        }
    }

    @Test func `asks to be connected until the widget opts in`() throws {
        let summary = AIUsageSummary.openCode(
            isConnected: false, usage: try usage, problem: nil, isStale: false, now: now)
        #expect(summary.limits.isEmpty)
        guard case .setup = summary.status else {
            Issue.record("not asking to connect")
            return
        }
    }

    @Test func `Go's windows in order, then the budgets`() throws {
        let summary = AIUsageSummary.openCode(
            isConnected: true, usage: try usage, problem: nil, isStale: false, now: now)
        #expect(summary.status == .limits)
        #expect(summary.limits.map(\.shortTitle) == ["5h", "wk", "mo", "$", "$"])
        #expect(summary.limits[4].title == "Budget · GLM-5.3, Kimi K3")
        #expect(summary.plan == "Go")
        #expect(summary.lead(at: now)?.id == "openCode.go.monthly")
        // The used-up month already says Go stopped.
        #expect(summary.notice == nil)
    }

    @Test func `a stop Go reports counts whatever the percentages say`() throws {
        var usage = try usage
        usage.go?[2].window.usedPercent = 80
        let summary = AIUsageSummary.openCode(isConnected: true, usage: usage, problem: nil, isStale: false, now: now)
        #expect(summary.notice == .init("Go usage limit reached", severity: .critical))
    }

    @Test func `pay-as-you-go alone has no limits`() {
        let summary = AIUsageSummary.openCode(
            isConnected: true, usage: OpenCodeUsage(fetchedAt: now), problem: nil, isStale: false, now: now)
        guard case .noLimits = summary.status else {
            Issue.record("has limits")
            return
        }
    }

    @Test func `a sign-in problem asks for a sign-in, others fail`() {
        let signIn = AIUsageSummary.openCode(
            isConnected: true, usage: nil, problem: .notSignedIn, isStale: false, now: now)
        guard case .setup = signIn.status else {
            Issue.record("not asking to sign in")
            return
        }
        let failed = AIUsageSummary.openCode(
            isConnected: true, usage: nil, problem: .unreachable, isStale: false, now: now)
        guard case .failed = failed.status else {
            Issue.record("not failed")
            return
        }
    }
}

struct OpenCodeUsageConfigurationTests {
    private func widget(_ settings: AIUsageSettings) -> WidgetInstance {
        WidgetInstance(settings: .aiUsage(settings))
    }

    @Test func `older AI Usage settings read without OpenCode's options`() throws {
        let settings = try JSONDecoder().decode(AIUsageSettings.self, from: Data(#"{"refreshesCursor":true}"#.utf8))
        #expect(!settings.refreshesOpenCode)
        #expect(settings.openCodeRefreshMinutes == 5)
        #expect(!settings.shownProviders.contains(.openCode))
    }

    @Test func `blocks keep their account, and hand-edited intervals are moved into range`() throws {
        let json = #"""
            {"blocks":[{"block":"openCode:6F1C2D3E-7A8B-4C9D-8E0F-A1B2C3D40004","shown":true}],
             "refreshesOpenCode":true,"openCodeRefreshMinutes":0}
            """#
        let settings = try JSONDecoder().decode(AIUsageSettings.self, from: Data(json.utf8))
        #expect(settings.blocks.shownBlocks == [.openCode])
        #expect(settings.openCodeRefreshMinutesIfOptedIn == 1)
    }

    @Test func `fetches the accounts opted-in widgets show, as often as the most frequent asks`() {
        let key = Account.key(.openCode, name: "Work")
        var configuration = AppConfiguration()
        configuration.accounts = [key]
        var work = AIUsageSettings(blocks: [], refreshesOpenCode: true, openCodeRefreshMinutes: 15)
        work.addBlock(.openCode, options: AIUsageBlockOptions(account: key.id))
        var cli = AIUsageSettings(blocks: [], refreshesOpenCode: true, openCodeRefreshMinutes: 2)
        cli.addBlock(.openCode, options: AIUsageBlockOptions(account: .openCodeCLI))
        cli.addBlock(.openCode, options: AIUsageBlockOptions(account: key.id))
        var off = AIUsageSettings(blocks: [], refreshesOpenCode: false)
        off.addBlock(.openCode)
        configuration.sections = [PanelSection(widgets: [widget(work), widget(cli), widget(off)])]

        let demand = configuration.serviceDemand(at: [.left])
        #expect(demand.usage.providers.contains(.openCode))
        #expect(demand.openCode == [key.id: 2, .openCodeCLI: 2])
        #expect(demand.limited(to: [.clock]).openCode.isEmpty)
    }

    @Test func `the default account is OpenCode's sign-in while it's signed in, else the only key`() {
        let key = Account.key(.openCode, name: "Work")
        var configuration = AppConfiguration()
        #expect(configuration.defaultAccount(for: .openCode) == .noAccount)
        #expect(configuration.defaultAccount(for: .openCode, signedIn: [.openCodeCLI]) == .account(.openCodeCLI))
        configuration.accounts = [key]
        #expect(configuration.defaultAccount(for: .openCode) == .account(key.id))
        #expect(configuration.defaultAccount(for: .openCode, signedIn: [.openCodeCLI]) == .account(.openCodeCLI))
    }
}
