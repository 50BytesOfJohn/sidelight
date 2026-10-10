import Foundation
import Testing

@testable import SidelightCore

struct RateLimitWindowTests {
    /// A 5-hour window that started at t = 0.
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private func session(_ percent: Double) -> RateLimitWindow {
        RateLimitWindow(usedPercent: percent, resetsAt: start.addingTimeInterval(5 * 3_600), durationMinutes: 300)
    }

    @Test func `elapsed fraction runs from start to reset`() {
        #expect(session(0).elapsedFraction(at: start.addingTimeInterval(3_600)) == 0.2)
        #expect(session(0).elapsedFraction(at: start.addingTimeInterval(-60)) == 0)
        #expect(session(0).elapsedFraction(at: start.addingTimeInterval(6 * 3_600)) == 1)
        #expect(RateLimitWindow(usedPercent: 0, durationMinutes: 300).elapsedFraction(at: start) == nil)
    }

    @Test func `pace compares usage with time passed`() {
        let oneHourIn = start.addingTimeInterval(3_600)
        // 20 % of the time gone: 20 % used just lasts, 40 % runs out after 2.5 hours.
        #expect(session(20).pace(at: oneHourIn) == .lasts)
        #expect(session(40).pace(at: oneHourIn) == .runsOut(at: start.addingTimeInterval(2.5 * 3_600)))
        #expect(session(100).pace(at: oneHourIn) == .reached)
        #expect(session(0).pace(at: oneHourIn) == .lasts)
    }

    @Test func `pace waits for a tenth of the window`() {
        #expect(session(30).pace(at: start.addingTimeInterval(10 * 60)) == .unknown)
        #expect(RateLimitWindow(usedPercent: 30).pace(at: start) == .unknown)
        // A used-up limit is known regardless.
        #expect(session(100).pace(at: start.addingTimeInterval(60)) == .reached)
    }

    @Test func `a window keeps its usage until it resets`() {
        let window = session(62)
        #expect(window.current(at: start.addingTimeInterval(3_600), resetsOnSchedule: false) == window)
    }

    @Test func `a session window starts over with no known reset`() {
        let current = session(62).current(at: start.addingTimeInterval(6 * 3_600), resetsOnSchedule: false)
        #expect(current == RateLimitWindow(usedPercent: 0, resetsAt: nil, durationMinutes: 300))
    }

    @Test func `a scheduled window moves on by whole windows`() {
        let reset = Date(timeIntervalSince1970: 2_000_000)
        let week = RateLimitWindow(usedPercent: 80, resetsAt: reset, durationMinutes: 7 * 24 * 60)
        let tenDaysLater = reset.addingTimeInterval(10 * 86_400)
        #expect(
            week.current(at: tenDaysLater, resetsOnSchedule: true)
                == RateLimitWindow(
                    usedPercent: 0, resetsAt: reset.addingTimeInterval(14 * 86_400), durationMinutes: 7 * 24 * 60)
        )
        // Exactly at the reset, the next window begins.
        #expect(week.current(at: reset, resetsOnSchedule: true).resetsAt == reset.addingTimeInterval(7 * 86_400))
    }
}

struct ClaudeCodeUsageTests {
    private let captured = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func `reads limits from status line input`() throws {
        let input = #"""
            {"model":{"display_name":"Opus"},"rate_limits":{
              "five_hour":{"used_percentage":62.5,"resets_at":1791010000},
              "seven_day":{"used_percentage":26,"resets_at":"oops"}}}
            """#
        let usage = try #require(ClaudeCodeUsage(statusLine: Data(input.utf8), capturedAt: captured))
        #expect(
            usage
                == ClaudeCodeUsage(
                    session: RateLimitWindow(
                        usedPercent: 62.5, resetsAt: Date(timeIntervalSince1970: 1_791_010_000), durationMinutes: 300),
                    weekly: RateLimitWindow(usedPercent: 26, resetsAt: nil, durationMinutes: 10_080),
                    capturedAt: captured,
                    source: .statusLine
                )
        )
    }

    @Test func `status line input without limits is nothing`() {
        #expect(ClaudeCodeUsage(statusLine: Data(#"{"model":{}}"#.utf8), capturedAt: captured) == nil)
        #expect(ClaudeCodeUsage(statusLine: Data(#"{"rate_limits":{}}"#.utf8), capturedAt: captured) == nil)
        #expect(ClaudeCodeUsage(statusLine: Data("not json".utf8), capturedAt: captured) == nil)
    }

    @Test func `reads the usage cache and plan from Claude Code's state`() throws {
        let state = #"""
            {"numStartups":3,
             "oauthAccount":{"accountUuid":"a1","organizationType":"claude_max"},
             "cachedUsageUtilization":{"fetchedAtMs":1791197763219,"accountUuid":"a1","utilization":{
               "five_hour":{"utilization":78,"resets_at":"2026-10-05T13:10:00.135826+00:00"},
               "seven_day":{"utilization":26.5,"resets_at":"2026-10-10T04:00:00+00:00"},
               "seven_day_opus":null}}}
            """#
        let decoded = try ClaudeCodeAccountState(data: Data(state.utf8))
        #expect(decoded.plan == "Max")
        let usage = try #require(decoded.usage)
        #expect(usage.source == .usageCache)
        #expect(usage.capturedAt == Date(timeIntervalSince1970: 1_791_197_763.219))
        #expect(usage.session?.usedPercent == 78)
        #expect(usage.session?.durationMinutes == 300)
        let sessionReset = try #require(usage.session?.resetsAt)
        #expect(abs(sessionReset.timeIntervalSince1970 - 1_791_205_800.135) < 0.01)
        #expect(usage.weekly?.resetsAt == Date(timeIntervalSince1970: 1_791_604_800))
    }

    @Test func `ignores another account's usage cache`() throws {
        let state = #"""
            {"oauthAccount":{"accountUuid":"a2","organizationType":"claude_pro"},
             "cachedUsageUtilization":{"fetchedAtMs":1,"accountUuid":"a1","utilization":{
               "five_hour":{"utilization":78}}}}
            """#
        #expect(try ClaudeCodeAccountState(data: Data(state.utf8)) == ClaudeCodeAccountState(plan: "Pro"))
    }

    @Test func `state without the parts Sidelight reads is empty`() throws {
        #expect(try ClaudeCodeAccountState(data: Data(#"{"projects":{}}"#.utf8)) == ClaudeCodeAccountState())
    }

    @Test func `plan names`() {
        #expect(ClaudeCodeAccountState.planName(organizationType: "claude_pro") == "Pro")
        #expect(ClaudeCodeAccountState.planName(organizationType: "claude_team_premium") == "Team Premium")
        #expect(ClaudeCodeAccountState.planName(organizationType: "claude_") == nil)
        #expect(ClaudeCodeAccountState.planName(organizationType: "enterprise") == nil)
    }

    @Test func `newest capture wins`() {
        let older = ClaudeCodeUsage(session: nil, weekly: nil, capturedAt: captured, source: .usageCache)
        let newer = ClaudeCodeUsage(
            session: nil, weekly: nil, capturedAt: captured.addingTimeInterval(1), source: .statusLine)
        #expect(ClaudeCodeUsage.newest(older, newer) == newer)
        #expect(ClaudeCodeUsage.newest(newer, older) == newer)
        #expect(ClaudeCodeUsage.newest(nil, older) == older)
        #expect(ClaudeCodeUsage.newest(nil, nil) == nil)
    }
}

struct ClaudeCodeUsageAPITests {
    private let received = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func `requests usage signed in with the access token`() {
        let request = ClaudeCodeUsageAPI.request(accessToken: "test-token", userAgent: "Sidelight/1.0")
        #expect(request.url == ClaudeCodeUsageAPI.url)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == ClaudeCodeUsageAPI.oauthBeta)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Sidelight/1.0")
    }

    @Test func `reads limits from a usage response`() throws {
        let body = #"""
            {"five_hour":{"utilization":41,"resets_at":"2026-10-05T13:10:00+00:00"},
             "seven_day":{"utilization":12.5,"resets_at":null},"seven_day_opus":null,"extra_usage":{"is_enabled":false}}
            """#
        let usage = try ClaudeCodeUsageAPI.result(status: 200, body: Data(body.utf8), receivedAt: received).get()
        #expect(
            usage
                == ClaudeCodeUsage(
                    session: RateLimitWindow(
                        usedPercent: 41, resetsAt: Date(timeIntervalSince1970: 1_791_205_800), durationMinutes: 300),
                    weekly: RateLimitWindow(usedPercent: 12.5, resetsAt: nil, durationMinutes: 10_080),
                    capturedAt: received,
                    source: .anthropic
                )
        )
    }

    @Test func `failed and unreadable responses are problems`() {
        let limits = Data(#"{"five_hour":{"utilization":41}}"#.utf8)
        #expect(throws: ClaudeCodeFetchProblem.rejected(status: 401)) {
            try ClaudeCodeUsageAPI.result(status: 401, body: limits, receivedAt: received).get()
        }
        #expect(throws: ClaudeCodeFetchProblem.rejected(status: 429)) {
            try ClaudeCodeUsageAPI.result(status: 429, body: Data(), receivedAt: received).get()
        }
        #expect(throws: ClaudeCodeFetchProblem.unreadable) {
            try ClaudeCodeUsageAPI.result(status: 200, body: Data(#"{"error":"x"}"#.utf8), receivedAt: received).get()
        }
        #expect(throws: ClaudeCodeFetchProblem.unreadable) {
            try ClaudeCodeUsageAPI.result(status: 200, body: Data("<html>".utf8), receivedAt: received).get()
        }
    }

    @Test func `failures back off up to a maximum`() {
        let interval = Duration.seconds(300)
        let maximum = Duration.seconds(3_600)
        #expect(ClaudeCodeUsageAPI.retryDelay(interval: interval, consecutiveFailures: 0, maximum: maximum) == interval)
        #expect(
            ClaudeCodeUsageAPI.retryDelay(interval: interval, consecutiveFailures: 1, maximum: maximum) == .seconds(600)
        )
        #expect(
            ClaudeCodeUsageAPI.retryDelay(interval: interval, consecutiveFailures: 2, maximum: maximum)
                == .seconds(1_200))
        #expect(ClaudeCodeUsageAPI.retryDelay(interval: interval, consecutiveFailures: 50, maximum: maximum) == maximum)
        // An interval longer than the maximum is never shortened.
        #expect(
            ClaudeCodeUsageAPI.retryDelay(interval: .seconds(7_200), consecutiveFailures: 3, maximum: maximum)
                == .seconds(7_200))
    }

    @Test func `reads Claude Code's stored sign-in`() throws {
        let stored = #"""
            {"claudeAiOauth":{"accessToken":"test-access","refreshToken":"test-refresh",
             "expiresAt":1791000000000,"scopes":["user:inference"],"subscriptionType":"max"}}
            """#
        let credentials = try ClaudeCodeCredentials(data: Data(stored.utf8))
        #expect(credentials.accessToken == "test-access")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_791_000_000))
        #expect(!credentials.isExpired(at: Date(timeIntervalSince1970: 1_790_999_999)))
        #expect(credentials.isExpired(at: Date(timeIntervalSince1970: 1_791_000_000)))
        #expect(!ClaudeCodeCredentials(accessToken: "t").isExpired(at: .distantFuture))
    }

    @Test func `sign-in without an access token is unreadable`() {
        #expect(throws: (any Error).self) { try ClaudeCodeCredentials(data: Data(#"{"claudeAiOauth":{}}"#.utf8)) }
        #expect(throws: (any Error).self) {
            try ClaudeCodeCredentials(data: Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8))
        }
        #expect(throws: (any Error).self) { try ClaudeCodeCredentials(data: Data(#"{"other":{}}"#.utf8)) }
    }
}

struct ClaudeCodeSettingsTests {
    @Test func `refresh is off by default`() {
        #expect(!ClaudeCodeSettings().refreshesFromAnthropic)
        #expect(ClaudeCodeSettings().refreshMinutes == 5)
    }

    @Test func `settings saved before the refresh options existed still load`() throws {
        let settings = try JSONDecoder().decode(
            ClaudeCodeSettings.self, from: Data(#"{"showsWeeklyLimit":false}"#.utf8))
        #expect(settings == ClaudeCodeSettings(showsWeeklyLimit: false))
    }

    @Test func `settings round-trip and keep the interval positive`() throws {
        let settings = ClaudeCodeSettings(showsWeeklyLimit: true, refreshesFromAnthropic: true, refreshMinutes: 15)
        let decoded = try JSONDecoder().decode(ClaudeCodeSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        let zero = try JSONDecoder().decode(ClaudeCodeSettings.self, from: Data(#"{"refreshMinutes":0}"#.utf8))
        #expect(zero.refreshMinutes == 1)
    }

    @Test func `the shortest opted-in interval wins`() {
        var configuration = AppConfiguration()
        #expect(configuration.claudeCodeRefreshMinutes == nil)
        configuration.sections = [
            PanelSection(widgets: [
                WidgetInstance(
                    settings: .claudeCode(ClaudeCodeSettings(refreshesFromAnthropic: true, refreshMinutes: 15))),
                WidgetInstance(
                    settings: .claudeCode(ClaudeCodeSettings(refreshesFromAnthropic: false, refreshMinutes: 2))),
            ]),
            PanelSection(widgets: [
                WidgetInstance(
                    settings: .claudeCode(ClaudeCodeSettings(refreshesFromAnthropic: true, refreshMinutes: 5)))
            ]),
        ]
        #expect(configuration.claudeCodeRefreshMinutes == 5)
    }
}
