import Foundation
import Testing

@testable import SidelightCore

struct CodexAppServerSessionTests {
    @Test func `handshake is two newline-terminated JSON lines`() throws {
        let lines = CodexAppServerSession.handshake(clientName: "sidelight", clientVersion: "1.0")
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.last == 0x0A })
        let initialize = try #require(try JSONSerialization.jsonObject(with: lines[0]) as? [String: Any])
        #expect(initialize["method"] as? String == "initialize")
        #expect(initialize["id"] as? Int == 1)
        let initialized = try #require(try JSONSerialization.jsonObject(with: lines[1]) as? [String: Any])
        #expect(initialized["id"] == nil)
        #expect(initialized["params"] == nil)
    }

    @Test func `matches responses to requests`() throws {
        var session = CodexAppServerSession()
        let id = try requestID(session.request(.readRateLimits))

        let response = #"""
            {"jsonrpc":"2.0","id":\#(id),"result":{
              "rateLimits":{"primary":{"usedPercent":42,"resetsAt":1791502532,"windowDurationMins":300},
                            "secondary":{"usedPercent":12.5,"windowDurationMins":10080},"planType":"plus",
                            "credits":{"hasCredits":true,"unlimited":false,"balance":"125.5"},
                            "rateLimitReachedType":null},
              "rateLimitResetCredits":{"availableCount":2},"ordinaryUsageAllowed":true}}
            """#
        let message = session.decode(Data(response.utf8))

        #expect(
            message
                == .rateLimits(
                    CodexRateLimitsReading(
                        rateLimits: CodexRateLimits(
                            primary: RateLimitWindow(
                                usedPercent: 42,
                                resetsAt: Date(timeIntervalSince1970: 1_791_502_532),
                                durationMinutes: 300
                            ),
                            secondary: RateLimitWindow(usedPercent: 12.5, durationMinutes: 10_080),
                            planType: "plus",
                            credits: CodexCredits(hasCredits: true, balance: "125.5")
                        ),
                        resetCredits: 2,
                        ordinaryUsageAllowed: true
                    )
                )
        )
        // A response is consumed once.
        #expect(session.decode(Data(response.utf8)) == nil)
    }

    @Test func `a window without its percentage is missing, not unused`() throws {
        var session = CodexAppServerSession()
        let id = try requestID(session.request(.readRateLimits))
        let response = #"""
            {"id":\#(id),"result":{"rateLimits":{"primary":{"resetsAt":1791502532,"windowDurationMins":300},
              "secondary":{"usedPercent":30,"windowDurationMins":10080}}}}
            """#
        guard case .rateLimits(let reading) = session.decode(Data(response.utf8)) else {
            Issue.record("Expected rate limits")
            return
        }
        #expect(reading.rateLimits.primary == nil)
        #expect(reading.rateLimits.secondary?.usedPercent == 30)
        // Not said is not allowed.
        #expect(reading.ordinaryUsageAllowed == nil)
    }

    @Test func `reports error responses for the request they answer`() throws {
        var session = CodexAppServerSession()
        let id = try requestID(session.request(.readRateLimits))
        let response = #"{"id":\#(id),"error":{"code":-32600,"message":"codex account authentication required"}}"#
        #expect(
            session.decode(Data(response.utf8))
                == .failed(.readRateLimits, message: "codex account authentication required")
        )
    }

    @Test func `account reads send the params object it requires`() throws {
        var session = CodexAppServerSession()
        let request = try #require(
            try JSONSerialization.jsonObject(with: session.request(.readAccount)) as? [String: Any]
        )
        #expect(request["method"] as? String == "account/read")
        #expect((request["params"] as? [String: Any])?.isEmpty == true)
    }

    @Test(arguments: [
        (#"{"account":null,"requiresOpenaiAuth":true}"#, CodexAccount.signedOut),
        (#"{"account":null,"requiresOpenaiAuth":false}"#, .otherProvider),
        (#"{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}"#, .apiKey),
        (
            #"{"account":{"type":"chatgpt","email":null,"planType":"pro"},"requiresOpenaiAuth":true}"#,
            .chatGPT(plan: "pro")
        ),
        (#"{"account":{"type":"amazonBedrock"},"requiresOpenaiAuth":false}"#, .otherProvider),
    ])
    func `decodes who Codex is signed in as`(result: String, account: CodexAccount) throws {
        var session = CodexAppServerSession()
        let id = try requestID(session.request(.readAccount))
        #expect(session.decode(Data(#"{"id":\#(id),"result":\#(result)}"#.utf8)) == .account(account))
    }

    @Test func `decodes usage buckets`() throws {
        var session = CodexAppServerSession()
        let request = session.request(.readUsage)
        let id = try #require((try JSONSerialization.jsonObject(with: request) as? [String: Any])?["id"] as? Int)
        let response = #"""
            {"id":\#(id),"result":{"summary":{"lifetimeTokens":123456789012},
             "dailyUsageBuckets":[{"startDate":"2026-10-08","tokens":1000},{"startDate":"2026-10-09","tokens":2.0e3}]}}
            """#
        #expect(
            session.decode(Data(response.utf8))
                == .usage(
                    CodexUsage(
                        lifetimeTokens: 123_456_789_012,
                        tokensByDay: ["2026-10-08": 1_000, "2026-10-09": 2_000]
                    )
                )
        )
    }

    @Test func `decodes notifications`() {
        var session = CodexAppServerSession()
        #expect(
            session.decode(Data(#"{"method":"account/updated","params":{"planType":"pro"}}"#.utf8))
                == .accountUpdated(plan: "pro")
        )
        #expect(
            session.decode(Data(#"{"method":"account/updated","params":{"authMode":null,"planType":null}}"#.utf8))
                == .accountUpdated(plan: nil)
        )
        #expect(
            session.decode(
                Data(
                    #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":5}}}}"#
                        .utf8)
            ) == .rateLimitsUpdated(CodexRateLimits(primary: RateLimitWindow(usedPercent: 5)))
        )
    }

    @Test(arguments: ["", "not json", #"{"id":999,"result":{}}"#, #"{"method":"thread/started","params":{}}"#])
    func `ignores irrelevant lines`(line: String) {
        var session = CodexAppServerSession()
        #expect(session.decode(Data(line.utf8)) == nil)
    }
}

private func requestID(_ request: Data) throws -> Int {
    try #require((try JSONSerialization.jsonObject(with: request) as? [String: Any])?["id"] as? Int)
}

struct CodexRateLimitsTests {
    let fiveHours = RateLimitWindow(usedPercent: 40, durationMinutes: 300)
    let week = RateLimitWindow(usedPercent: 70, durationMinutes: 10_080)

    @Test func `sparse updates keep what they leave out`() {
        let known = CodexRateLimits(
            primary: fiveHours, secondary: week, planType: "plus", credits: CodexCredits(hasCredits: true))
        let update = CodexRateLimits(primary: RateLimitWindow(usedPercent: 45, durationMinutes: 300))

        let merged = known.merging(update)

        #expect(merged.primary?.usedPercent == 45)
        #expect(merged.secondary == week)
        #expect(merged.planType == "plus")
        #expect(merged.credits == CodexCredits(hasCredits: true))
    }

    @Test func `limits are named and ordered by their window, not their slot`() {
        // Free plans can have just a weekly window, sent as the primary one.
        let free = CodexRateLimits(primary: week).limits()
        #expect(free.map(\.title) == ["Weekly"])
        #expect(free.map(\.segments) == [7])

        let swapped = CodexRateLimits(primary: week, secondary: fiveHours).limits()
        #expect(swapped.map(\.title) == ["5-hour", "Weekly"])
        #expect(swapped.map(\.shortTitle) == ["5h", "wk"])
        #expect(swapped.map(\.segments) == [5, 7])
    }

    @Test func `hiding the weekly limit never hides the only one`() {
        #expect(
            CodexRateLimits(primary: fiveHours, secondary: week).limits(includesLonger: false).map(\.title) == [
                "5-hour"
            ])
        #expect(CodexRateLimits(primary: week).limits(includesLonger: false).map(\.title) == ["Weekly"])
    }

    @Test func `windows of unknown or odd length still get a name`() {
        let limits = CodexRateLimits(
            primary: RateLimitWindow(usedPercent: 1), secondary: RateLimitWindow(usedPercent: 2, durationMinutes: 90)
        )
        .limits()
        #expect(limits.map(\.title) == ["Usage limit", "90-minute"])
        #expect(limits.map(\.segments) == [1, 1])
    }

    @Test func `the tightest limit skips windows that have reset since`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = CodexLimit(
            role: .primary, window: RateLimitWindow(usedPercent: 95, resetsAt: now.addingTimeInterval(-60)))
        let weekly = CodexLimit(
            role: .secondary, window: RateLimitWindow(usedPercent: 50, resetsAt: now.addingTimeInterval(3_600)))

        #expect(reset.hasReset(at: now))
        #expect(CodexLimit.tightest([reset, weekly], at: now) == weekly)
        #expect(CodexLimit.tightest([reset], at: now) == reset)
    }
}

struct CodexUsageTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return calendar
    }()

    @Test func `daily totals are oldest first and zero-filled`() throws {
        let usage = CodexUsage(tokensByDay: ["2026-10-07": 5, "2026-10-09": 9])
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 23)))
        #expect(usage.dailyTotals(endingOn: day, days: 4, calendar: calendar) == [0, 5, 0, 9])
        #expect(usage.tokens(on: day, calendar: calendar) == 9)
    }
}

struct CodexRolloutTests {
    @Test func `takes the last token_count event with rate limits`() {
        let log = """
            {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10}},"rate_limits":{"primary":{"used_percent":10.0,"window_minutes":300,"resets_at":100}}}}
            {"type":"event_msg","payload":{"type":"agent_message","message":"hi"}}
            {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":16626447}},"rate_limits":{"primary":{"used_percent":66.0,"window_minutes":300,"resets_at":1791502532},"secondary":{"used_percent":39.0,"window_minutes":10080,"resets_at":1791963323},"plan_type":"plus"}}}
            {"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}
            """
        #expect(
            CodexRollout.latestSnapshot(inLog: Data(log.utf8))
                == CodexRolloutSnapshot(
                    rateLimits: CodexRateLimits(
                        primary: RateLimitWindow(
                            usedPercent: 66,
                            resetsAt: Date(timeIntervalSince1970: 1_791_502_532),
                            durationMinutes: 300
                        ),
                        secondary: RateLimitWindow(
                            usedPercent: 39,
                            resetsAt: Date(timeIntervalSince1970: 1_791_963_323),
                            durationMinutes: 10_080
                        ),
                        planType: "plus"
                    ),
                    sessionTokens: 16_626_447
                )
        )
    }

    @Test func `dates a snapshot by its event`() throws {
        let log = """
            {"timestamp":"2026-10-10T07:15:42.123Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":5.0}}}}
            """
        let snapshot = try #require(CodexRollout.latestSnapshot(inLog: Data(log.utf8)))
        let capturedAt = try #require(snapshot.capturedAt)
        #expect(abs(capturedAt.timeIntervalSince1970 - 1_791_616_542.123) < 0.01)
    }

    @Test func `finds the newest rollout file`() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let older = root.appending(path: "2026/09/30")
        let newer = root.appending(path: "2026/10/02")
        for directory in [older, newer, root.appending(path: "notes")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data().write(to: older.appending(path: "rollout-a.jsonl"))
        try Data().write(to: newer.appending(path: "rollout-b.jsonl"))
        try Data().write(to: newer.appending(path: "other.txt"))

        #expect(CodexRollout.newestRolloutFile(in: root)?.lastPathComponent == "rollout-b.jsonl")
    }
}
