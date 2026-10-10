import Foundation
import SQLite3
import Testing

@testable import SidelightCore

/// Responses shaped like cursor.com/api/usage-summary, with made-up values.
private enum Fixture {
    static let proPlus = #"""
        {"billingCycleStart":"2026-10-01T09:00:00.000Z","billingCycleEnd":"2026-10-31T09:00:00.000Z",
         "membershipType":"pro_plus","limitType":"user","isUnlimited":false,
         "autoModelSelectedDisplayMessage":"You've used 45% of your included total usage",
         "namedModelSelectedDisplayMessage":"You've used 97% of your included API usage",
         "individualUsage":{
           "plan":{"enabled":true,"used":0,"limit":0,"remaining":0,
                   "breakdown":{"included":7000,"bonus":0,"total":7000},
                   "autoPercentUsed":39.9,"apiPercentUsed":97.2,"totalPercentUsed":44.7},
           "onDemand":{"enabled":true,"used":1250,"limit":5000,"remaining":3750}},
         "teamUsage":{}}
        """#

    static let team = #"""
        {"billingCycleStart":"2026-10-01T00:00:00Z","billingCycleEnd":"2026-11-01T00:00:00Z",
         "membershipType":"enterprise","limitType":"team","isUnlimited":false,
         "individualUsage":{"overall":{"enabled":true,"used":6907,"limit":45000,"remaining":38093},
                            "onDemand":{"enabled":false,"used":0,"limit":null}},
         "teamUsage":{"onDemand":{"enabled":true,"used":250000,"limit":1000000,"remaining":750000}}}
        """#

    static let unlimited = #"{"membershipType":"enterprise","isUnlimited":true,"individualUsage":{}}"#

    /// A JWT with these claims and a fake signature; Sidelight never verifies it.
    static func token(claims: String) -> String {
        func base64URL(_ string: String) -> String {
            Data(string.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(base64URL(#"{"alg":"HS256","typ":"JWT"}"#)).\(base64URL(claims)).fake-signature"
    }

    static let signedIn = token(claims: #"{"sub":"auth0|user_01FAKEFAKEFAKE","exp":1793000000,"scope":"openid"}"#)
}

struct CursorUsageTests {
    private let fetched = Date(timeIntervalSince1970: 1_791_000_000)
    private let cycleStart = Date(timeIntervalSince1970: 1_790_845_200)  // 2026-10-01 09:00 UTC
    private let cycleEnd = Date(timeIntervalSince1970: 1_793_437_200)  // 2026-10-31 09:00 UTC

    @Test func `reads both pools, the cycle and on-demand spending`() throws {
        let usage = try #require(CursorUsage(usageSummary: Data(Fixture.proPlus.utf8), fetchedAt: fetched))
        let window = { (percent: Double) in
            RateLimitWindow(usedPercent: percent, resetsAt: self.cycleEnd, durationMinutes: 30 * 24 * 60)
        }
        #expect(
            usage
                == CursorUsage(
                    membershipType: "pro_plus",
                    limitType: "user",
                    billingCycle: DateInterval(start: cycleStart, end: cycleEnd),
                    pools: [
                        CursorUsagePool(
                            kind: .cursorModels, window: window(39.9),
                            message: "You've used 45% of your included total usage"),
                        CursorUsagePool(
                            kind: .otherModels, window: window(97.2),
                            message: "You've used 97% of your included API usage"),
                    ],
                    totalPercentUsed: 44.7,
                    onDemand: CursorSpending(isEnabled: true, used: 1250, limit: 5000),
                    fetchedAt: fetched
                )
        )
        #expect(usage.planName == "Pro+")
        #expect(usage.tightestPool?.kind == .otherModels)
        #expect(usage.onDemand?.usedPercent == 25)
    }

    @Test func `a team member's single allowance is one pool`() throws {
        let usage = try #require(CursorUsage(usageSummary: Data(Fixture.team.utf8), fetchedAt: fetched))
        #expect(usage.pools.map(\.kind) == [.included])
        let percent = try #require(usage.pools.first?.window.usedPercent)
        #expect(abs(percent - 15.348_888) < 0.001)
        #expect(usage.pools.first?.window.durationMinutes == 31 * 24 * 60)
        #expect(usage.onDemand == CursorSpending(isEnabled: false, used: 0, limit: nil))
        #expect(usage.teamOnDemand?.usedPercent == 25)
        #expect(usage.planName == "Enterprise")
    }

    @Test func `the blended total stands in when there are no pools`() throws {
        let body = #"{"membershipType":"free","individualUsage":{"plan":{"totalPercentUsed":12}}}"#
        let usage = try #require(CursorUsage(usageSummary: Data(body.utf8), fetchedAt: fetched))
        #expect(usage.pools == [CursorUsagePool(kind: .included, window: RateLimitWindow(usedPercent: 12))])
        #expect(usage.planName == "Hobby")
    }

    @Test func `an unlimited plan has no pools`() throws {
        let usage = try #require(CursorUsage(usageSummary: Data(Fixture.unlimited.utf8), fetchedAt: fetched))
        #expect(usage.isUnlimited)
        #expect(usage.pools.isEmpty)
        #expect(usage.tightestPool == nil)
    }

    @Test func `responses without usage are nothing`() {
        for body in [
            "{}", #"{"error":"not_authenticated"}"#, "<html></html>", "[]",
            #"{"individualUsage":{"plan":{"enabled":false,"autoPercentUsed":10}}}"#,
            #"{"individualUsage":{"plan":{"autoPercentUsed":"lots"}}}"#,
        ] {
            #expect(CursorUsage(usageSummary: Data(body.utf8), fetchedAt: fetched) == nil, "\(body)")
        }
    }

    @Test func `odd fields break only themselves`() throws {
        let body = #"""
            {"billingCycleStart":1790845200000,"billingCycleEnd":"1793437200000","membershipType":7,
             "isUnlimited":"no","individualUsage":{"plan":{"autoPercentUsed":120,"apiPercentUsed":-3},
             "onDemand":{"used":"x"}}}
            """#
        let usage = try #require(CursorUsage(usageSummary: Data(body.utf8), fetchedAt: fetched))
        #expect(usage.billingCycle == DateInterval(start: cycleStart, end: cycleEnd))
        #expect(usage.membershipType == nil)
        #expect(!usage.isUnlimited)
        #expect(usage.pools.map(\.window.usedPercent) == [100, 0])
        #expect(usage.onDemand == nil)
    }

    @Test func `a cycle that ended starts again from zero`() throws {
        let usage = try #require(CursorUsage(usageSummary: Data(Fixture.proPlus.utf8), fetchedAt: fetched))
        let during = cycleEnd.addingTimeInterval(-60)
        #expect(!usage.cycleHasEnded(at: during))
        #expect(usage.current(at: during) == usage)

        let after = cycleEnd.addingTimeInterval(3_600)
        let current = usage.current(at: after)
        #expect(usage.cycleHasEnded(at: after))
        #expect(current.pools.map(\.window.usedPercent) == [0, 0])
        #expect(current.pools.allSatisfy { $0.window.resetsAt == nil && $0.message == nil })
        #expect(current.totalPercentUsed == 0)
        #expect(current.onDemand?.used == 0)
    }

    @Test func `pace forecasts over the billing cycle`() throws {
        let usage = try #require(CursorUsage(usageSummary: Data(Fixture.proPlus.utf8), fetchedAt: fetched))
        let halfway = cycleStart.addingTimeInterval(15 * 86_400)
        // Half the cycle gone: 39.9 % of Cursor models lasts, 97.2 % of API models runs out before the reset.
        #expect(usage.pools[0].window.pace(at: halfway) == .lasts)
        guard case .runsOut(let date) = usage.pools[1].window.pace(at: halfway) else {
            Issue.record("expected the API pool to run out")
            return
        }
        #expect(date > halfway && date < cycleEnd)
    }

    @Test func `plan names`() {
        #expect(CursorUsage.planName(membershipType: "pro") == "Pro")
        #expect(CursorUsage.planName(membershipType: "ULTRA") == "Ultra")
        #expect(CursorUsage.planName(membershipType: "free_trial") == "Trial")
        #expect(CursorUsage.planName(membershipType: "new_tier") == "New Tier")
        #expect(CursorUsage.planName(membershipType: "") == nil)
    }

    @Test func `on-demand spending is only a share of its limit`() {
        #expect(CursorSpending(isEnabled: true, used: 30, limit: nil).usedPercent == nil)
        #expect(CursorSpending(isEnabled: true, used: 30, limit: 0).usedPercent == nil)
        #expect(CursorSpending(isEnabled: true, used: 900, limit: 600).usedPercent == 100)
        #expect(CursorSpending(isEnabled: true, used: nil, limit: 600).usedPercent == 0)
    }
}

struct CursorUsageAPITests {
    private let received = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func `requests usage with the dashboard's session cookie`() throws {
        let signIn = try #require(CursorSignIn(accessToken: Fixture.signedIn, source: .app))
        let request = CursorUsageAPI.request(signIn: signIn, userAgent: "Sidelight/1.0")
        #expect(request.url == CursorUsageAPI.url)
        #expect(request.httpMethod == "GET")
        #expect(!request.httpShouldHandleCookies)
        #expect(
            request.value(forHTTPHeaderField: "Cookie")
                == "WorkosCursorSessionToken=user_01FAKEFAKEFAKE%3A%3A\(Fixture.signedIn)")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Sidelight/1.0")
    }

    @Test func `reads usage from a response`() throws {
        let usage = try CursorUsageAPI.result(status: 200, body: Data(Fixture.proPlus.utf8), receivedAt: received).get()
        #expect(usage.fetchedAt == received)
        #expect(usage.pools.count == 2)
    }

    @Test func `failed and unreadable responses are problems`() {
        #expect(throws: CursorFetchProblem.rejected(status: 401)) {
            try CursorUsageAPI.result(status: 401, body: Data(Fixture.proPlus.utf8), receivedAt: received).get()
        }
        #expect(throws: CursorFetchProblem.rejected(status: 429)) {
            try CursorUsageAPI.result(status: 429, body: Data(), receivedAt: received).get()
        }
        #expect(throws: CursorFetchProblem.unreadable) {
            try CursorUsageAPI.result(status: 200, body: Data("<html>".utf8), receivedAt: received).get()
        }
        #expect(CursorFetchProblem.rejected(status: 401).isSignInRejection)
        #expect(CursorFetchProblem.rejected(status: 403).isSignInRejection)
        #expect(!CursorFetchProblem.rejected(status: 500).isSignInRejection)
        #expect(!CursorFetchProblem.unreachable.isSignInRejection)
    }
}

struct CursorSignInTests {
    @Test func `reads the user and expiry from the token`() throws {
        let signIn = try #require(CursorSignIn(accessToken: Fixture.signedIn, source: .cli))
        #expect(signIn.userID == "user_01FAKEFAKEFAKE")
        #expect(signIn.expiresAt == Date(timeIntervalSince1970: 1_793_000_000))
        #expect(signIn.source == .cli)
        #expect(!signIn.isExpired(at: Date(timeIntervalSince1970: 1_792_999_999)))
        #expect(signIn.isExpired(at: Date(timeIntervalSince1970: 1_793_000_000)))
    }

    @Test func `accepts a token stored as a JSON string or with a newline`() throws {
        let quoted = try #require(CursorSignIn(accessToken: "\"\(Fixture.signedIn)\"\n", source: .app))
        #expect(quoted.accessToken == Fixture.signedIn)
    }

    @Test func `a subject without a provider is the user`() throws {
        let token = Fixture.token(claims: #"{"sub":"user_02FAKE"}"#)
        let signIn = try #require(CursorSignIn(accessToken: token, source: .app))
        #expect(signIn.userID == "user_02FAKE")
        #expect(signIn.expiresAt == nil)
        #expect(!signIn.isExpired(at: .distantFuture))
    }

    @Test func `tokens Sidelight can't read are no sign-in`() {
        for token in [
            "", "not-a-jwt", "a.b", "a.b.c.d", "a.!!!.c", Fixture.token(claims: #"{"exp":1}"#),
            Fixture.token(claims: #"{"sub":""}"#), Fixture.token(claims: #"{"sub":"auth0|"}"#),
        ] {
            #expect(CursorSignIn(accessToken: token, source: .app) == nil, "\(token)")
        }
    }

    @Test func `its description leaves the token out`() throws {
        let signIn = try #require(CursorSignIn(accessToken: Fixture.signedIn, source: .app))
        #expect(!String(describing: signIn).contains(signIn.accessToken))
        #expect(!String(describing: signIn).contains("fake-signature"))
    }
}

struct EditorStateDatabaseTests {
    /// A state database like Cursor's, with made-up values.
    private func makeDatabase(_ rows: [(String, String)], table: String = "ItemTable") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "sidelight-\(UUID().uuidString).vscdb")
        var connection: OpaquePointer?
        try #require(sqlite3_open(url.path(percentEncoded: false), &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        let create = "CREATE TABLE \(table) (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)"
        try #require(sqlite3_exec(connection, create, nil, nil, nil) == SQLITE_OK)
        for (key, value) in rows {
            try #require(
                sqlite3_exec(connection, "INSERT INTO \(table) VALUES ('\(key)', '\(value)')", nil, nil, nil)
                    == SQLITE_OK)
        }
        return url
    }

    @Test func `reads a value by key`() throws {
        let database = try makeDatabase([
            ("cursorAuth/cachedEmail", "someone@example.com"), (CursorSignIn.appTokenKey, Fixture.signedIn),
        ])
        defer { try? FileManager.default.removeItem(at: database) }
        #expect(EditorStateDatabase.value(forKey: CursorSignIn.appTokenKey, in: database) == Fixture.signedIn)
        #expect(EditorStateDatabase.value(forKey: "cursorAuth/refreshToken", in: database) == nil)
        // Keys are matched exactly, not as SQL.
        #expect(EditorStateDatabase.value(forKey: "' OR 1=1 --", in: database) == nil)
    }

    @Test func `a missing database or table is nothing, and isn't created`() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "sidelight-\(UUID().uuidString).vscdb")
        #expect(EditorStateDatabase.value(forKey: CursorSignIn.appTokenKey, in: missing) == nil)
        #expect(!FileManager.default.fileExists(atPath: missing.path(percentEncoded: false)))

        let other = try makeDatabase([(CursorSignIn.appTokenKey, "x")], table: "OtherTable")
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(EditorStateDatabase.value(forKey: CursorSignIn.appTokenKey, in: other) == nil)
    }
}

struct CursorSettingsTests {
    @Test func `fetching is off by default, every 15 minutes`() {
        let settings = CursorSettings()
        #expect(!settings.refreshesFromCursor)
        #expect(settings.refreshMinutes == 15)
        #expect(settings.showsOnDemand)
    }

    @Test func `partial settings load with defaults`() throws {
        let settings = try JSONDecoder().decode(
            CursorSettings.self, from: Data(#"{"refreshesFromCursor":true}"#.utf8))
        #expect(settings == CursorSettings(refreshesFromCursor: true))
        let zero = try JSONDecoder().decode(CursorSettings.self, from: Data(#"{"refreshMinutes":0}"#.utf8))
        #expect(zero.refreshMinutes == 1)
    }

    @Test func `a widget round-trips through config json`() throws {
        var configuration = AppConfiguration()
        let widget = WidgetInstance(
            settings: .cursor(CursorSettings(refreshesFromCursor: true, refreshMinutes: 30, showsOnDemand: false)))
        configuration.sections = [PanelSection(widgets: [widget])]
        let decoded = try AppConfiguration(json: configuration.json())
        #expect(decoded.widgets == [widget])
    }

    @Test func `a widget saved without settings loads with defaults`() throws {
        let json = #"""
            {"id":"5B2B0F7E-6C1B-4F4A-9C11-0E8C3D1A2B3C","kind":"cursor","showsInSidePanel":true,"showsInBar":false}
            """#
        let widget = try JSONDecoder().decode(WidgetInstance.self, from: Data(json.utf8))
        #expect(widget.settings == .cursor(CursorSettings()))
        #expect(!widget.showsInBar)
    }

    @Test func `the shortest opted-in interval wins`() {
        var configuration = AppConfiguration()
        #expect(configuration.cursorRefreshMinutes == nil)
        configuration.sections = [
            PanelSection(widgets: [
                WidgetInstance(settings: .cursor(CursorSettings(refreshesFromCursor: true, refreshMinutes: 30))),
                WidgetInstance(settings: .cursor(CursorSettings(refreshesFromCursor: false, refreshMinutes: 5))),
                WidgetInstance(
                    settings: .claudeCode(ClaudeCodeSettings(refreshesFromAnthropic: true, refreshMinutes: 2))),
            ]),
            PanelSection(widgets: [
                WidgetInstance(settings: .cursor(CursorSettings(refreshesFromCursor: true, refreshMinutes: 15)))
            ]),
        ]
        #expect(configuration.cursorRefreshMinutes == 15)
        #expect(configuration.claudeCodeRefreshMinutes == 2)
    }
}
