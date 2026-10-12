import Foundation
import Testing

@testable import SidelightCore

struct AgentSessionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func claude(_ id: String, activity: ClaudeSession.Activity = .idle, age: TimeInterval = 0) -> AgentSession {
        AgentSession(ClaudeSession(id: id, title: "Fixture", activity: activity, since: now.addingTimeInterval(-age)))
    }

    @Test func `identity survives process changes and separates providers`() {
        var original = ClaudeSession(id: "shared", title: "Before", activity: .working, since: now, pid: 100)
        let first = AgentSession(original)
        original.pid = 200
        original.title = "After"
        let second = AgentSession(original)
        let codex = AgentSession(CodexSession(id: "shared", title: "Fixture", activity: .idle, since: now))
        let cursor = AgentSession(CursorChat(id: "shared", updatedAt: now))
        #expect(first.id == second.id)
        #expect(Set([first.id, second.id, codex.id, cursor.id]).count == 3)
        #expect(first.id.sessionID == "shared")
    }

    @Test(arguments: [
        (ClaudeSession.Activity.needsInput("permission"), AgentSession.Status.needsInput("permission")),
        (.working, .working(nil)), (.finished, .finished), (.idle, .idle), (.closed, .closed), (.unknown, .unknown),
    ])
    func `Claude activities retain their meaning`(activity: ClaudeSession.Activity, expected: AgentSession.Status) {
        #expect(claude("c", activity: activity).status == expected)
    }

    @Test(arguments: [
        (CodexSession.Activity.needsApproval("reason"), AgentSession.Status.needsApproval("reason")),
        (.needsInput, .needsInput(nil)), (.working(reviewing: true), .working("auto-review")),
        (.working(reviewing: false), .working(nil)), (.finished, .finished), (.stopped, .interrupted),
        (.idle, .idle), (.closed, .closed),
    ])
    func `Codex activities retain approval and interruption`(
        activity: CodexSession.Activity, expected: AgentSession.Status
    ) {
        let session = AgentSession(CodexSession(id: "x", title: "Fixture", activity: activity, since: now))
        #expect(session.status == expected)
        #expect(session.status.needsUser == activity.needsUser)
        #expect(session.status.isOngoing == activity.isOngoing)
    }

    @Test func `provider metadata and every surface survive adaptation`() {
        let claudeSurfaces: [(ClaudeSessionSurface, AgentSession.Surface)] = [
            (.terminal, .terminal), (.desktop, .desktopApp), (.vscode, .editor), (.sdk, .background),
            (.background, .background),
        ]
        for (surface, expected) in claudeSurfaces {
            let session = AgentSession(
                ClaudeSession(
                    id: "c", title: "Name", project: "demo", surface: surface,
                    activity: .idle, since: now, pid: 1, cwd: "/tmp/demo", desktopSessionID: "local_fixture"))
            #expect(session.surface == expected)
            #expect(session.cwd == "/tmp/demo")
            #expect(session.isOpen == true)
            #expect(session.project == "demo")
        }
        let surfaces: [(CodexSessionSurface, AgentSession.Surface)] = [
            (.terminal, .terminal), (.desktop, .desktopApp), (.ide, .editor), (.exec, .background),
            (.other("custom"), .other("custom")),
        ]
        for (surface, expected) in surfaces {
            let session = AgentSession(
                CodexSession(
                    id: "x", title: "Name", project: "demo", branch: "main",
                    cwd: "/tmp/demo", surface: surface, activity: .closed, since: now))
            #expect(session.surface == expected)
            #expect(session.branch == "main")
            #expect(session.isOpen == false)
        }
        let cursor = AgentSession(CursorChat(id: "q", workspacePath: "/tmp/demo", updatedAt: now))
        #expect(cursor.title == "Untitled chat")
        #expect(cursor.status == .untracked)
        #expect(cursor.surface == .editor)
        #expect(cursor.isOpen == nil)
        #expect(cursor.project == "demo")
        #expect(cursor.since == now)
    }

    @Test func `urgency outranks freshness with deterministic ties across providers`() {
        let waiting = claude("wait", activity: .needsInput(nil), age: 100_000)
        let working = claude("work", activity: .working, age: 90_000)
        let done = claude("done", activity: .finished, age: 10_000)
        let recent = claude("recent")
        let a = claude("a")
        let codex = AgentSession(CodexSession(id: "x", title: "Fixture", activity: .idle, since: now))
        let cursor = AgentSession(CursorChat(id: "x", updatedAt: now))
        let groups = [[cursor, working, recent], [done, codex, a, waiting]]
        let expected = [waiting.id, working.id, done.id, a.id, recent.id, codex.id, cursor.id]
        #expect(AgentSession.merged(groups).map(\.id) == expected)
        #expect(AgentSession.merged(groups.reversed().map { Array($0.reversed()) }).map(\.id) == expected)
    }

    @Test func `recent window includes boundary and ongoing sessions and advances without source changes`() {
        let input = [
            claude("boundary", age: 3600), claude("outside", age: 3600.001),
            claude("working", activity: .working, age: 100_000),
            claude("waiting", activity: .needsInput(nil), age: 100_000),
            claude("unknown", activity: .unknown, age: 3601),
        ]
        #expect(input.recent(within: 3600, now: now).map(\.id.sessionID) == ["boundary", "working", "waiting"])
        #expect(
            input.recent(within: 3600, now: now.addingTimeInterval(60)).map(\.id.sessionID) == ["working", "waiting"])
        #expect([claude("future", age: -60)].recent(within: 3600, now: now).count == 1)
    }
}

struct AgentSessionsSettingsTests {
    private func decode(_ json: String) throws -> AgentSessionsSettings {
        try JSONDecoder().decode(AgentSessionsSettings.self, from: Data(json.utf8))
    }

    @Test func `missing and wrong types fall back while future providers are skipped`() throws {
        #expect(try decode("{}") == AgentSessionsSettings())
        #expect(
            try decode(#"{"providers":null,"sessionCount":"many","recentHours":false,"includesCodexExec":42}"#)
                == AgentSessionsSettings())
        let settings = try decode(#"{"providers":["cursor","future","codex","cursor"],"futureOption":true}"#)
        #expect(settings.providers == [.codex, .cursor])
        #expect(try decode(#"{"providers":["future"]}"#).providers.isEmpty)
        #expect(try decode(#"{"providers":[]}"#).providers.isEmpty)
    }

    @Test(arguments: [(-50, 1), (0, 1), (1, 1), (10, 10), (100, 10)])
    func `saved counts are clamped`(value: Int, expected: Int) throws {
        #expect(try decode("{\"sessionCount\":\(value)}").sessionCount == expected)
    }

    @Test func `provider changes are canonical idempotent and can select none`() throws {
        var settings = AgentSessionsSettings(providers: [.cursor, .codex, .cursor])
        settings.set(.claudeCode, included: true)
        settings.set(.claudeCode, included: true)
        #expect(settings.providers == AgentProvider.allCases)
        for provider in AgentProvider.allCases { settings.set(provider, included: false) }
        #expect(settings.providers.isEmpty)
        #expect(!settings.includes(.codex))
        settings.set(.cursor, included: true)
        #expect(settings.includes(.cursor))
        #expect(try decode(#"{"recentHours":-1}"#).recentWindow == 3600)
        for hours in [1, 4, 12, 24, 48] {
            settings.recentHours = hours
            #expect(settings.recentWindow == Double(hours * 3600))
            #expect(
                try JSONDecoder().decode(AgentSessionsSettings.self, from: JSONEncoder().encode(settings)) == settings)
        }
    }

    @Test func `combined and existing standalone widgets round trip without migration`() throws {
        var configuration = AppConfiguration()
        configuration.sections = [
            PanelSection(widgets: [
                WidgetInstance(
                    settings: .agentSessions(
                        AgentSessionsSettings(
                            providers: [], sessionCount: 7,
                            recentHours: 12, includesCodexExec: true))), WidgetInstance(kind: .claudeSessions),
                WidgetInstance(kind: .codexSessions), WidgetInstance(kind: .codex), WidgetInstance(kind: .claudeCode),
                WidgetInstance(kind: .cursor), WidgetInstance(kind: .aiUsage),
            ])
        ]
        #expect(try AppConfiguration(json: configuration.json()) == configuration)
        for kind in ["agentSessions", "claudeSessions", "codexSessions"] {
            let json =
                #"{"id":"00000000-0000-0000-0000-000000000001","kind":"\#(kind)","showsInSidePanel":true,"showsInBar":false}"#
            let widget = try JSONDecoder().decode(WidgetInstance.self, from: Data(json.utf8))
            #expect(widget.kind.rawValue == kind)
            #expect(widget.showsInSidePanel && !widget.showsInBar)
        }
    }
}

struct AgentSessionDemandTests {
    private func configuration(_ widgets: [WidgetInstance]) -> AppConfiguration {
        var configuration = AppConfiguration()
        configuration.sections = [PanelSection(widgets: widgets)]
        return configuration
    }

    @Test func `combined only starts selected session sources and no usage sources`() {
        let config = configuration([
            WidgetInstance(settings: .agentSessions(AgentSessionsSettings(providers: [.cursor])))
        ])
        let demand = config.serviceDemand(at: [.left])
        #expect(demand.sessions == [.cursor])
        #expect(demand.usage.providers.isEmpty)
        #expect(demand.kinds == [.agentSessions])
    }

    @Test func `standalone combined and multiple panels union demand once`() {
        let combined = WidgetInstance(settings: .agentSessions(AgentSessionsSettings(providers: [.codex, .cursor])))
        let config = configuration([
            combined, combined.duplicated(), WidgetInstance(kind: .codexSessions),
            WidgetInstance(kind: .claudeSessions),
        ])
        #expect(
            config.serviceDemand(at: [.left, .right, .top, .bottom, .left]).sessions == Set(AgentProvider.allCases))
        #expect(config.visibleWidgets(at: [.left, .right]).count == 4)
        #expect(config.serviceDemand(at: []).sessions.isEmpty)
    }

    @Test func `hiding removing and deselecting release service demand`() {
        var widget = WidgetInstance(settings: .agentSessions(AgentSessionsSettings(providers: [.cursor, .codex])))
        widget.showsInSidePanel = false
        #expect(configuration([widget]).serviceDemand(at: [.left, .right]).sessions.isEmpty)
        #expect(configuration([widget]).serviceDemand(at: [.top]).sessions == [.cursor, .codex])
        widget.showsInBar = false
        #expect(configuration([widget]).serviceDemand(at: [.left, .top]).sessions.isEmpty)
        widget.showsInSidePanel = true
        widget.settings = .agentSessions(AgentSessionsSettings(providers: []))
        #expect(configuration([widget]).serviceDemand(at: [.left]).sessions.isEmpty)
        #expect(configuration([]).serviceDemand(at: [.left]).sessions.isEmpty)
    }

    @Test func `Widgets previews request every session source including hidden widgets`() {
        let widget = WidgetInstance(
            settings: .agentSessions(AgentSessionsSettings(providers: [])),
            showsInSidePanel: false, showsInBar: false)
        let demand = configuration([widget]).serviceDemand(at: [], previewsEveryWidget: true)
        #expect(demand.sessions == Set(AgentProvider.allCases))
        #expect(demand.usage.providers == Set(AIUsageProvider.allCases))
        #expect(demand.placedKinds == [.agentSessions])
    }
}

struct AgentSessionEventRegressionTests {
    @Test(arguments: ["task_started", "turn_started"])
    func `both Codex start event names begin a turn`(name: String) {
        let state = Rollout.state([Rollout.line("11:00:01.000", "event_msg", #"{"type":"\#(name)","turn_id":"t"}"#)])
        #expect(state.turn == .running(since: Rollout.date("11:00:01.000")))
    }

    @Test(arguments: ["task_complete", "turn_complete"])
    func `both Codex completion names finish the turn and clear approval`(name: String) {
        let state = Rollout.state([
            Rollout.started("11:00:00.000"),
            Rollout.functionCall(
                "11:00:01.000", id: "pending", name: "exec_command",
                arguments: #"{"cmd":"echo fixture","sandbox_permissions":"require_escalated"}"#),
            Rollout.line(
                "11:00:02.000", "event_msg",
                #"{"type":"\#(name)","turn_id":"t","last_agent_message":"Fixture","duration_ms":2000}"#),
        ])
        #expect(state.turn == .completed(at: Rollout.date("11:00:02.000")))
        #expect(state.pendingCalls.isEmpty)
        #expect(state.lastMessage == "Fixture")
        #expect(state.lastTurnDuration == 2)
    }

    @Test func `Claude future status with timestamp stays unknown after observed work`() {
        let start = Date(timeIntervalSince1970: 100)
        var tracker = ClaudeSessionTracker()
        tracker.update(
            records: [ClaudeSessionRecord(pid: 1, sessionID: "x", startedAt: start, status: .busy)],
            titles: [:], now: start)
        tracker.update(
            records: [
                ClaudeSessionRecord(
                    pid: 1, sessionID: "x", startedAt: start, status: .unknown,
                    statusChangedAt: start.addingTimeInterval(60))
            ], titles: [:], now: start.addingTimeInterval(60))
        #expect(tracker.sessions.first?.activity == .unknown)
        #expect(tracker.sessions.map(AgentSession.init).first?.status == .unknown)
    }

    @Test func `explicit future Claude status without timestamp is still unknown`() throws {
        let record = try #require(
            ClaudeSessionRecord(
                json: Data(#"{"pid":1,"sessionId":"x","startedAt":100000,"status":"future-working"}"#.utf8)))
        var tracker = ClaudeSessionTracker()
        tracker.update(records: [record], titles: [:], now: Date(timeIntervalSince1970: 100))
        #expect(tracker.sessions.first?.activity == .unknown)
    }

    @Test func `Claude without a status is idle at startup`() throws {
        let record = try #require(
            ClaudeSessionRecord(json: Data(#"{"pid":1,"sessionId":"x","startedAt":100000}"#.utf8)))
        var tracker = ClaudeSessionTracker()
        tracker.update(records: [record], titles: [:], now: Date(timeIntervalSince1970: 100))
        #expect(tracker.sessions.first?.activity == .idle)
    }

}

struct ClaudeStatusPostFixTests {
    @Test(arguments: ["\"future-status\"", "\"\"", "3", "false", "{}", "[]"])
    func explicitUnknownNeverMeansFinished(status: String) throws {
        for timestamp in ["", ",\"statusUpdatedAt\":106000"] {
            for priorBusy in [false, true] {
                let json = "{\"pid\":1,\"sessionId\":\"x\",\"startedAt\":100000,\"status\":\(status)\(timestamp)}"
                let record = try #require(ClaudeSessionRecord(json: Data(json.utf8)))
                #expect(record.status == .unknown)
                var tracker = ClaudeSessionTracker()
                if priorBusy {
                    var busy = record
                    busy.status = .busy
                    tracker.update(records: [busy], titles: [:], now: record.startedAt)
                }
                tracker.update(records: [record], titles: [:], now: record.startedAt.addingTimeInterval(10))
                let session = try #require(tracker.sessions.first)
                #expect(session.activity == .unknown)
                #expect(AgentSession(session).status == .unknown)
            }
        }
    }

    @Test(arguments: ["", ",\"status\":null"])
    func absentStatusKeepsStartupAndWorkedSemantics(status: String) throws {
        let noTimestamp = "{\"pid\":1,\"sessionId\":\"x\",\"startedAt\":100000\(status)}"
        let startup = try #require(ClaudeSessionRecord(json: Data(noTimestamp.utf8)))
        var startupTracker = ClaudeSessionTracker()
        startupTracker.update(records: [startup], titles: [:], now: startup.startedAt)
        #expect(startupTracker.sessions.first?.activity == .idle)
        var busyStartup = startup
        busyStartup.status = .busy
        startupTracker.update(records: [busyStartup], titles: [:], now: startup.startedAt)
        startupTracker.update(records: [startup], titles: [:], now: startup.startedAt)
        #expect(startupTracker.sessions.first?.activity == .finished)
        for (offset, expected) in [(0, ClaudeSession.Activity.idle), (5000, .idle), (5001, .finished)] {
            let json =
                "{\"pid\":1,\"sessionId\":\"x\",\"startedAt\":100000,\"statusUpdatedAt\":\(100000 + offset)\(status)}"
            let record = try #require(ClaudeSessionRecord(json: Data(json.utf8)))
            #expect(record.status == .notWritten)
            var tracker = ClaudeSessionTracker()
            tracker.update(records: [record], titles: [:], now: record.startedAt)
            #expect(tracker.sessions.first?.activity == expected)
            var busy = record
            busy.status = .busy
            tracker.update(records: [busy], titles: [:], now: record.startedAt)
            tracker.update(records: [record], titles: [:], now: record.startedAt)
            #expect(tracker.sessions.first?.activity == .finished)
        }
    }
}
