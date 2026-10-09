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
        let request = session.request(.readRateLimits)
        let id = try #require((try JSONSerialization.jsonObject(with: request) as? [String: Any])?["id"] as? Int)

        let response = #"""
            {"jsonrpc":"2.0","id":\#(id),"result":{
              "rateLimits":{"primary":{"usedPercent":42,"resetsAt":1791502532,"windowDurationMins":300},
                            "secondary":{"usedPercent":12.5,"windowDurationMins":10080},"planType":"plus"},
              "rateLimitResetCredits":{"availableCount":2}}}
            """#
        let message = session.decode(Data(response.utf8))

        #expect(
            message
                == .rateLimits(
                    CodexRateLimits(
                        primary: RateLimitWindow(
                            usedPercent: 42,
                            resetsAt: Date(timeIntervalSince1970: 1_791_502_532),
                            durationMinutes: 300
                        ),
                        secondary: RateLimitWindow(usedPercent: 12.5, durationMinutes: 10_080),
                        planType: "plus"
                    ),
                    resetCredits: 2
                )
        )
        // A response is consumed once.
        #expect(session.decode(Data(response.utf8)) == nil)
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
                == .planUpdated("pro")
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
