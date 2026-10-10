import Foundation
import Testing

@testable import SidelightCore

struct ClaudeSessionRecordTests {
    /// As Claude Code 2.1.295 writes it for a session in the desktop app.
    static let desktop = """
        {"pid":54918,"sessionId":"1727b210-707b-4482-bac5-acc953988a7c","cwd":"/Users/me/Developer/sidelight",\
        "startedAt":1791637640278,"procStart":"Sat Oct 10 13:07:17 2026","version":"2.1.295","peerProtocol":1,\
        "kind":"interactive","entrypoint":"claude-desktop","hostSessionId":"local_a9d6a8bf","name":"Logo concepts",\
        "nameSource":"user","status":"idle","updatedAt":1791637867637,"statusUpdatedAt":1791637867637}
        """

    @Test func `reads a desktop session`() throws {
        let record = try #require(ClaudeSessionRecord(json: Data(Self.desktop.utf8)))
        #expect(record.pid == 54918)
        #expect(record.sessionID == "1727b210-707b-4482-bac5-acc953988a7c")
        #expect(record.name == "Logo concepts")
        #expect(record.isNamed)
        #expect(record.status == .idle)
        #expect(record.surface == .desktop)
        #expect(record.desktopSessionID == "local_a9d6a8bf")
        #expect(record.project == "sidelight")
        #expect(record.startedAt == Date(timeIntervalSince1970: 1_791_637_640.278))
        #expect(record.statusChangedAt == Date(timeIntervalSince1970: 1_791_637_867.637))
    }

    @Test func `reads a waiting terminal session with a derived name`() throws {
        let json = """
            {"pid":7,"sessionId":"s","startedAt":1000,"kind":"interactive","entrypoint":"cli","name":"sidelight-bc",\
            "nameSource":"derived","status":"waiting","waitingFor":"permission prompt","statusUpdatedAt":2000}
            """
        let record = try #require(ClaudeSessionRecord(json: Data(json.utf8)))
        #expect(record.status == .waiting)
        #expect(record.waitingFor == "permission prompt")
        #expect(!record.isNamed)
        #expect(record.surface == .terminal)
    }

    @Test func `maps statuses and surfaces like Claude Code's agent view`() throws {
        func record(_ fields: String) throws -> ClaudeSessionRecord {
            try #require(ClaudeSessionRecord(json: Data(#"{"pid":1,"sessionId":"s","startedAt":0,\#(fields)}"#.utf8)))
        }
        #expect(try record(#""status":"busy""#).status == .busy)
        #expect(try record(#""status":"shell""#).status == .idle)
        #expect(try record(#""status":"dreaming""#).status == .unknown)
        #expect(try record(#""status":3"#).status == .unknown)
        #expect(try record(#""kind":"background","entrypoint":"cli""#).surface == .background)
        #expect(try record(#""kind":"interactive","entrypoint":"sdk-cli""#).surface == .sdk)
        #expect(try record(#""entrypoint":"claude-vscode""#).surface == .vscode)
        #expect(try record(#""entrypoint":"local-agent""#).surface == .desktop)
        #expect(try record(#""spare":true"#).isSpare)
    }

    @Test func `skips files it can't match to a process`() {
        #expect(ClaudeSessionRecord(json: Data(#"{"sessionId":"s","startedAt":0}"#.utf8)) == nil)
        #expect(ClaudeSessionRecord(json: Data(#"{"pid":1,"startedAt":0}"#.utf8)) == nil)
        #expect(ClaudeSessionRecord(json: Data(#"{"pid":1,"sessionId":"s"}"#.utf8)) == nil)
        #expect(ClaudeSessionRecord(json: Data(#"{"pid":1,"sessionId":"s","st"#.utf8)) == nil)
    }
}

struct ClaudeTranscriptTests {
    @Test func `prefers the newest name the user chose`() {
        let lines = """
            {"type":"user","message":{"content":"the custom-title is mentioned here"}}
            {"type":"ai-title","aiTitle":"Generated","sessionId":"s"}
            {"type":"custom-title","customTitle":"Mine","sessionId":"s"}
            {"type":"ai-title","aiTitle":"Generated again","sessionId":"s"}
            {"type":"custom-title","customTitle":"Mine, renamed","sessionId":"s"}
            """
        #expect(ClaudeTranscript.title(in: Data(lines.utf8)) == "Mine, renamed")
    }

    @Test func `falls back to the generated title and skips cut-off lines`() {
        let lines = """
            le":"Cut off","sessionId":"s"}
            {"type":"ai-title","aiTitle":"Generated","sessionId":"s"}
            {"type":"custom-title","customTitle":"  ","sessionId":"s"}
            {"type":"ai-title","aiTitle":"Cut o
            """
        #expect(ClaudeTranscript.title(in: Data(lines.utf8)) == "Generated")
        #expect(ClaudeTranscript.title(in: Data(#"{"type":"user"}"#.utf8)) == nil)
    }

    @Test func `falls back to the latest prompt when there's no title`() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "prompt.jsonl")
        let lines = """
            {"type":"last-prompt","lastPrompt":"First ask"}
            {"type":"last-prompt","lastPrompt":"Fix the\\n  flaky   test"}
            """
        try Data(lines.utf8).write(to: url)
        #expect(ClaudeTranscript.title(at: url) == "Fix the flaky test")
        #expect(ClaudeTranscript.title(in: Data(lines.utf8)) == nil)
    }

    @Test func `reads the title from either end of a long transcript`() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let filler = String(
            repeating: #"{"type":"assistant","text":"\#(String(repeating: "x", count: 500))"}"# + "\n", count: 300)

        let headOnly = directory.appending(path: "head.jsonl")
        try Data((#"{"type":"ai-title","aiTitle":"At the start"}"# + "\n" + filler).utf8).write(to: headOnly)
        #expect(ClaudeTranscript.title(at: headOnly) == "At the start")

        let both = directory.appending(path: "both.jsonl")
        let text = #"{"type":"ai-title","aiTitle":"Old"}"# + "\n" + filler + #"{"type":"ai-title","aiTitle":"New"}"#
        try Data(text.utf8).write(to: both)
        #expect(ClaudeTranscript.title(at: both) == "New")
    }

    @Test func `finds the transcript by its working directory, or by looking in every project`() throws {
        let projects = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: projects) }
        let named = projects.appending(path: "-Users-me-my-app--claude-worktrees-x")
        let other = projects.appending(path: "-elsewhere")
        for folder in [named, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data().write(to: named.appending(path: "a.jsonl"))
        try Data().write(to: other.appending(path: "b.jsonl"))

        let a = ClaudeTranscript.url(
            sessionID: "a", cwd: "/Users/me/my_app/.claude/worktrees/x", projectsDirectory: projects)
        #expect(a?.lastPathComponent == "a.jsonl")
        #expect(a?.deletingLastPathComponent().lastPathComponent == named.lastPathComponent)
        let b = ClaudeTranscript.url(sessionID: "b", cwd: "/somewhere/else", projectsDirectory: projects)
        #expect(b?.deletingLastPathComponent().lastPathComponent == "-elsewhere")
        #expect(ClaudeTranscript.url(sessionID: "c", cwd: nil, projectsDirectory: projects) == nil)
    }
}

struct ClaudeSessionTrackerTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func record(
        _ id: String, _ status: ClaudeSessionRecord.Status, changedAfter seconds: TimeInterval = 0,
        pid: Int32 = 1, name: String? = nil, isNamed: Bool = false, isSpare: Bool = false
    ) -> ClaudeSessionRecord {
        ClaudeSessionRecord(
            pid: pid, sessionID: id, cwd: "/code/\(id)", name: name, isNamed: isNamed, startedAt: start,
            status: status, statusChangedAt: start.addingTimeInterval(seconds), isSpare: isSpare)
    }

    @Test func `a session that worked and went idle is finished`() {
        var tracker = ClaudeSessionTracker()
        tracker.update(records: [record("a", .idle, changedAfter: 1)], titles: [:], now: start)
        #expect(tracker.sessions.map(\.activity) == [.idle])
        tracker.update(records: [record("a", .busy, changedAfter: 2)], titles: [:], now: start)
        #expect(tracker.sessions.map(\.activity) == [.working])
        tracker.update(records: [record("a", .idle, changedAfter: 3)], titles: [:], now: start)
        #expect(tracker.sessions.map(\.activity) == [.finished])
        #expect(tracker.sessions.first?.since == start.addingTimeInterval(3))
    }

    @Test func `an idle session found later is finished when its status changed after it opened`() {
        var tracker = ClaudeSessionTracker()
        tracker.update(
            records: [record("a", .idle, changedAfter: 600), record("b", .idle, changedAfter: 1, pid: 2)],
            titles: [:], now: start.addingTimeInterval(900))
        #expect(tracker.sessions.map(\.id) == ["a", "b"])
        #expect(tracker.sessions.map(\.activity) == [.finished, .idle])
    }

    @Test func `a session whose process is gone is closed, then forgotten after a day`() {
        var tracker = ClaudeSessionTracker()
        tracker.update(records: [record("a", .busy, changedAfter: 1)], titles: [:], now: start)
        let closedAt = start.addingTimeInterval(60)
        #expect(tracker.sessions.first?.pid == 1)
        tracker.update(records: [], titles: [:], now: closedAt)
        #expect(tracker.sessions.map(\.activity) == [.closed])
        #expect(tracker.sessions.first?.pid == nil)
        #expect(tracker.sessions.first?.since == closedAt)
        tracker.update(records: [], titles: [:], now: closedAt.addingTimeInterval(3_600))
        #expect(tracker.sessions.first?.since == closedAt)
        tracker.update(records: [], titles: [:], now: closedAt.addingTimeInterval(ClaudeSessionTracker.closedRetention))
        #expect(tracker.sessions.isEmpty)
    }

    @Test func `a closed session that's resumed is live again`() {
        var tracker = ClaudeSessionTracker()
        tracker.update(records: [record("a", .idle, changedAfter: 60)], titles: [:], now: start)
        tracker.update(records: [], titles: [:], now: start.addingTimeInterval(120))
        tracker.update(records: [record("a", .busy, changedAfter: 180, pid: 9)], titles: [:], now: start)
        #expect(tracker.sessions.map(\.activity) == [.working])
    }

    @Test func `sorts what needs the user first, then what's working, then the newest`() {
        var tracker = ClaudeSessionTracker()
        tracker.update(
            records: [
                record("done", .idle, changedAfter: 500, pid: 1),
                record("old", .idle, changedAfter: 100, pid: 2),
                record("busy", .busy, changedAfter: 10, pid: 3),
                record("ask", .waiting, changedAfter: 5, pid: 4),
                record("spare", .idle, pid: 5, isSpare: true),
            ],
            titles: [:], now: start)
        #expect(tracker.sessions.map(\.id) == ["ask", "busy", "done", "old"])
    }

    @Test func `the newest record wins when a session is open twice`() {
        var tracker = ClaudeSessionTracker()
        tracker.update(
            records: [record("a", .busy, changedAfter: 50, pid: 1), record("a", .idle, changedAfter: 90, pid: 2)],
            titles: [:], now: start)
        #expect(tracker.sessions.map(\.activity) == [.finished])
    }

    @Test func `titles come from a chosen name, then the transcript, then the derived name`() {
        let named = record("a", .idle, name: "Logo concepts", isNamed: true)
        let derived = record("b", .idle, name: "b-x1")
        let bare = record("c", .idle)
        #expect(ClaudeSessionTracker.title(of: named, transcriptTitle: "From transcript") == "Logo concepts")
        #expect(ClaudeSessionTracker.title(of: derived, transcriptTitle: "From transcript") == "From transcript")
        #expect(ClaudeSessionTracker.title(of: derived, transcriptTitle: nil) == "b-x1")
        #expect(ClaudeSessionTracker.title(of: bare, transcriptTitle: nil) == "c")
    }

    @Test func `recent keeps ongoing sessions however old`() {
        let now = start.addingTimeInterval(10 * 3_600)
        let sessions = [
            ClaudeSession(id: "busy", title: "", activity: .working, since: start),
            ClaudeSession(id: "ask", title: "", activity: .needsInput(nil), since: start),
            ClaudeSession(id: "old", title: "", activity: .finished, since: start),
            ClaudeSession(id: "new", title: "", activity: .closed, since: now.addingTimeInterval(-60)),
        ]
        #expect(sessions.recent(within: 3_600, now: now).map(\.id) == ["busy", "ask", "new"])
    }
}

struct ClaudeSessionsSettingsTests {
    @Test func `decodes missing and out-of-range options`() throws {
        let empty = try JSONDecoder().decode(ClaudeSessionsSettings.self, from: Data("{}".utf8))
        #expect(empty == ClaudeSessionsSettings())
        let odd = try JSONDecoder().decode(
            ClaudeSessionsSettings.self, from: Data(#"{"sessionCount":40,"recentHours":0}"#.utf8))
        #expect(odd.sessionCount == ClaudeSessionsSettings.sessionCountRange.upperBound)
        #expect(odd.recentHours == 1)
    }

    @Test func `round-trips in a widget`() throws {
        let widget = WidgetInstance(settings: .claudeSessions(ClaudeSessionsSettings(sessionCount: 3, recentHours: 12)))
        let decoded = try JSONDecoder().decode(WidgetInstance.self, from: JSONEncoder().encode(widget))
        #expect(decoded == widget)
    }
}

struct ProcessTableTests {
    @Test func `tells a running process from one that took its ID later`() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let start = ProcessTable.startDate(of: pid)
        #expect(start != nil)
        #expect(ProcessTable.isRunning(pid, startedBy: .now))
        #expect(!ProcessTable.isRunning(pid, startedBy: Date(timeIntervalSince1970: 0)))
        #expect(ProcessTable.startDate(of: -1) == nil)
    }

    @Test func `walks up to the processes that started this one`() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let ancestry = ProcessTable.ancestry(of: pid)
        #expect(ancestry.first == pid)
        #expect(ancestry.count >= 2)
        #expect(ProcessTable.parent(of: pid) == ancestry[1])
        #expect(ProcessTable.parent(of: 1) == nil)
        #expect(ProcessTable.ancestry(of: pid, limit: 1) == [pid])
    }
}

struct ClaudeSessionLinksTests {
    @Test func `opens desktop sessions by the app's own ID only`() {
        #expect(
            ClaudeSessionLinks.desktopURL(sessionID: "local_a9d6a8bf-29aa")?.absoluteString
                == "claude://code/continue?session=local_a9d6a8bf-29aa")
        #expect(ClaudeSessionLinks.desktopURL(sessionID: "1727b210-707b") == nil)
        #expect(ClaudeSessionLinks.desktopURL(sessionID: "local_x&session=last") == nil)
    }

    @Test func `quotes the resume command for the shell`() {
        #expect(
            ClaudeSessionLinks.resumeCommand(sessionID: "ab-1", cwd: "/code/app")
                == "cd /code/app && claude --resume ab-1")
        #expect(
            ClaudeSessionLinks.resumeCommand(sessionID: "ab-1", cwd: "/My Code/it's")
                == #"cd '/My Code/it'\''s' && claude --resume ab-1"#)
        #expect(ClaudeSessionLinks.resumeCommand(sessionID: "ab-1", cwd: nil) == "claude --resume ab-1")
    }

    @Test func `scripts the terminals that can find a tab`() throws {
        func script(_ bundleID: String, tty: String? = "/dev/ttys003", cwd: String? = "/code") -> String? {
            TerminalFocusScript.script(bundleID: bundleID, tty: tty, workingDirectory: cwd, title: "Fix it")
        }
        #expect(try #require(script(TerminalFocusScript.terminalBundleID)).contains(#"tty of aTab is "/dev/ttys003""#))
        #expect(try #require(script(TerminalFocusScript.iTermBundleID)).contains(#"tty of aSession is "/dev/ttys003""#))
        #expect(try #require(script(TerminalFocusScript.ghosttyBundleID)).contains(#"working directory is "/code""#))
        #expect(script(TerminalFocusScript.terminalBundleID, tty: nil) == nil)
        #expect(script(TerminalFocusScript.ghosttyBundleID, cwd: nil) == nil)
        #expect(script("net.kovidgoyal.kitty") == nil)
    }

    @Test func `escapes AppleScript strings`() {
        #expect(TerminalFocusScript.literal(#"a "b" \ c"#) == #""a \"b\" \\ c""#)
        #expect(TerminalFocusScript.literal("one\ntwo") == #""one two""#)
    }
}

struct ShortAgeTests {
    @Test func `uses the largest unit`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Formatting.shortAge(since: now.addingTimeInterval(-30), now: now) == "now")
        #expect(Formatting.shortAge(since: now.addingTimeInterval(-14 * 60), now: now) == "14m")
        #expect(Formatting.shortAge(since: now.addingTimeInterval(-2 * 3_600), now: now) == "2h")
        #expect(Formatting.shortAge(since: now.addingTimeInterval(-3 * 86_400), now: now) == "3d")
    }
}
