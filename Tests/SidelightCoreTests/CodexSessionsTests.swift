import Foundation
import SQLite3
import Testing

@testable import SidelightCore

/// Rollout lines as Codex 0.162 writes them, cut down to the fields that matter.
enum Rollout {
    static func line(_ time: String, _ type: String, _ payload: String) -> String {
        #"{"timestamp":"2026-10-11T\#(time)Z","ordinal":1,"type":"\#(type)","payload":\#(payload)}"#
    }

    static let meta = line(
        "11:00:00.000", "session_meta",
        #"{"id":"t1","cwd":"/code/app","originator":"codex-tui","source":"cli","thread_source":"user"}"#)
    static func started(_ time: String) -> String {
        line(time, "event_msg", #"{"type":"task_started","turn_id":"turn"}"#)
    }
    static func completed(_ time: String, message: String = "All done.") -> String {
        line(
            time, "event_msg",
            #"{"type":"task_complete","turn_id":"turn","last_agent_message":"\#(message)","duration_ms":35348}"#)
    }
    static func aborted(_ time: String) -> String {
        line(time, "event_msg", #"{"type":"turn_aborted","turn_id":"turn","reason":"interrupted"}"#)
    }
    static func codeCall(_ time: String, id: String, script: String) -> String {
        let input = String(decoding: try! JSONEncoder().encode(script), as: UTF8.self)
        return line(
            time, "response_item",
            #"{"type":"custom_tool_call","status":"completed","call_id":"\#(id)","name":"exec","input":\#(input)}"#)
    }
    static func functionCall(_ time: String, id: String, name: String, arguments: String) -> String {
        let encoded = String(decoding: try! JSONEncoder().encode(arguments), as: UTF8.self)
        return line(
            time, "response_item",
            #"{"type":"function_call","name":"\#(name)","arguments":\#(encoded),"call_id":"\#(id)"}"#)
    }
    static func output(_ time: String, id: String) -> String {
        line(
            time, "response_item",
            #"{"type":"custom_tool_call_output","id":"ctco_1","call_id":"\#(id)","output":[{"type":"input_text","text":"ok"}]}"#
        )
    }
    static func tokenCount(_ time: String, tokens: Int, window: Int = 258_400) -> String {
        line(
            time, "event_msg",
            #"{"type":"token_count","info":{"total_token_usage":{"total_tokens":999999},"last_token_usage":{"total_tokens":\#(tokens)},"model_context_window":\#(window)},"rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1791731233},"secondary":{"used_percent":2.0,"window_minutes":10080,"resets_at":1792298805},"plan_type":"plus"}}"#
        )
    }
    static func fileChange(_ time: String, paths: [String]) -> String {
        let changes = paths.map { #""\#($0)":{"type":"update","unified_diff":"@@"}"# }.joined(separator: ",")
        return line(
            time, "event_msg",
            #"{"type":"item_completed","thread_id":"t1","turn_id":"turn","item":{"type":"FileChange","id":"x","changes":{\#(changes)}}}"#
        )
    }
    static func agentMessage(_ time: String, _ text: String) -> String {
        line(
            time, "event_msg",
            #"{"type":"item_completed","thread_id":"t1","turn_id":"turn","item":{"type":"AgentMessage","id":"m","content":[{"type":"Text","text":"\#(text)"}]}}"#
        )
    }

    static func state(_ lines: [String]) -> CodexRolloutState {
        var follower = CodexRolloutFollower()
        follower.consume(Data(lines.map { $0 + "\n" }.joined().utf8))
        return follower.state
    }

    static func date(_ time: String) -> Date {
        CodexRolloutReducer.parseDate("2026-10-11T\(time)Z")!
    }
}

struct CodexRolloutFollowerTests {
    @Test func `follows a turn from start to end`() {
        let running = Rollout.state([Rollout.meta, Rollout.started("11:00:01.000")])
        #expect(running.turn == .running(since: Rollout.date("11:00:01.000")))

        let done = Rollout.state([Rollout.meta, Rollout.started("11:00:01.000"), Rollout.completed("11:00:36.000")])
        #expect(done.turn == .completed(at: Rollout.date("11:00:36.000")))
        #expect(done.lastMessage == "All done.")
        #expect(done.lastTurnDuration == 35.348)

        let stopped = Rollout.state([Rollout.started("11:00:01.000"), Rollout.aborted("11:00:04.000")])
        #expect(stopped.turn == .aborted(at: Rollout.date("11:00:04.000")))
    }

    @Test func `a call asking for escalated permissions waits until its output`() throws {
        let script =
            #"text(await tools.exec_command({cmd:"make dev",sandbox_permissions:"require_escalated",justification:"May I launch the app?"}));"#
        let waiting = Rollout.state([
            Rollout.started("11:00:01.000"), Rollout.codeCall("11:00:05.000", id: "call_1", script: script),
        ])
        let pending = try #require(waiting.firstPendingCall)
        #expect(pending.kind == .escalation(justification: "May I launch the app?"))
        #expect(pending.calledAt == Rollout.date("11:00:05.000"))

        let answered = Rollout.state([
            Rollout.started("11:00:01.000"), Rollout.codeCall("11:00:05.000", id: "call_1", script: script),
            Rollout.output("11:00:09.000", id: "call_1"),
        ])
        #expect(answered.pendingCalls.isEmpty)
    }

    @Test func `recognizes escalations and questions in function calls too`() {
        let state = Rollout.state([
            Rollout.started("11:00:01.000"),
            Rollout.functionCall(
                "11:00:02.000", id: "a", name: "exec_command",
                arguments:
                    #"{"cmd":"git push","sandbox_permissions":"require_escalated","justification":"Push the tag"}"#),
            Rollout.functionCall("11:00:03.000", id: "b", name: "request_user_input", arguments: #"{"questions":[]}"#),
            Rollout.functionCall("11:00:04.000", id: "c", name: "exec_command", arguments: #"{"cmd":"ls"}"#),
        ])
        #expect(state.pendingCalls["a"]?.kind == .escalation(justification: "Push the tag"))
        #expect(state.pendingCalls["b"]?.kind == .question)
        #expect(state.pendingCalls["c"] == nil)
    }

    @Test func `a new turn forgets the last one's calls and changes`() {
        let script = #"tools.exec_command({cmd:"x",sandbox_permissions:"require_escalated"})"#
        let state = Rollout.state([
            Rollout.started("11:00:01.000"), Rollout.codeCall("11:00:02.000", id: "a", script: script),
            Rollout.fileChange("11:00:03.000", paths: ["/code/app/a.swift"]), Rollout.aborted("11:00:04.000"),
            Rollout.started("11:01:00.000"),
        ])
        #expect(state.pendingCalls.isEmpty)
        #expect(state.changedFiles.isEmpty)
    }

    @Test func `reads the plan however a script passes it`() {
        let direct = Rollout.state([
            Rollout.functionCall(
                "11:00:02.000", id: "p", name: "update_plan",
                arguments:
                    #"{"plan":[{"step":"Audit","status":"completed"},{"step":"Fix \"it\"","status":"in_progress"},{"step":"Ship","status":"pending"}]}"#
            )
        ])
        #expect(
            direct.plan == [
                CodexPlanStep("Audit", .completed), CodexPlanStep(#"Fix "it""#, .inProgress),
                CodexPlanStep("Ship", .pending),
            ])
        #expect(direct.planIsCurrent)

        // Code mode, looking the tool up by name, with unquoted keys.
        let looked = Rollout.state([
            Rollout.codeCall(
                "11:00:02.000", id: "p",
                script:
                    #"const t = ALL_TOOLS.find(x => /update_plan$/.test(x.name)); await tools[t.name]({plan:[{step:"Prepare",status:"completed"},{step:"Write",status:"in_progress"}]});"#
            )
        ])
        #expect(looked.plan == [CodexPlanStep("Prepare", .completed), CodexPlanStep("Write", .inProgress)])

        let unrelated = Rollout.state([
            Rollout.codeCall("11:00:02.000", id: "x", script: #"tools.exec_command({cmd:"echo plan: [1]"})"#)
        ])
        #expect(unrelated.plan.isEmpty)
    }

    @Test func `the plan stays but is no longer current after a new turn starts`() {
        let state = Rollout.state([
            Rollout.functionCall(
                "11:00:02.000", id: "p", name: "update_plan",
                arguments: #"{"plan":[{"step":"Audit","status":"completed"}]}"#),
            Rollout.completed("11:00:10.000"), Rollout.started("11:05:00.000"),
        ])
        #expect(state.plan.count == 1)
        #expect(!state.planIsCurrent)
    }

    @Test func `context left matches Codex's own percentage`() {
        let state = Rollout.state([Rollout.tokenCount("11:00:02.000", tokens: 109_449)])
        let context = state.context!
        #expect(context.tokens == 109_449)
        #expect(context.window == 258_400)
        // Codex leaves a 12,000-token baseline out of both: (246,400 - 97,449) / 246,400.
        #expect(abs(context.percentLeft - 60.45) < 0.01)
        #expect(CodexContextUsage(tokens: 5_000, window: 258_400).percentLeft == 100)
        #expect(CodexContextUsage(tokens: 300_000, window: 258_400).percentLeft == 0)
        #expect(state.rateLimits?.primary?.usedPercent == 12)
        #expect(state.rateLimitsCapturedAt == Rollout.date("11:00:02.000"))
    }

    @Test func `counts files changed and keeps the latest message`() {
        let state = Rollout.state([
            Rollout.started("11:00:01.000"),
            Rollout.fileChange("11:00:02.000", paths: ["/code/app/a.swift", "/code/app/b.swift"]),
            Rollout.fileChange("11:00:03.000", paths: ["/code/app/a.swift"]),
            Rollout.agentMessage("11:00:04.000", "Changed   two\\nfiles."),
        ])
        #expect(state.changedFiles == ["/code/app/a.swift", "/code/app/b.swift"])
        #expect(state.lastMessage == "Changed two files.")
    }

    @Test func `reads the session's details from its first line`() {
        let reviewer = Rollout.line(
            "11:00:00.000", "session_meta",
            #"{"id":"g","parent_thread_id":"t1","originator":"Codex Desktop","source":{"subagent":{"other":"guardian"}},"thread_source":"guardian_review"}"#
        )
        let meta = CodexRolloutReducer.meta(in: Data(reviewer.utf8))
        #expect(meta == CodexSessionMeta(originator: "Codex Desktop", parentThreadID: "t1", isApprovalReviewer: true))
        #expect(CodexRolloutReducer.meta(in: Data(Rollout.meta.utf8))?.originator == "codex-tui")
        #expect(CodexRolloutReducer.meta(in: Data(Rollout.started("11:00:00.000").utf8)) == nil)
    }

    @Test func `a line split across reads is read once it's whole`() {
        let line = Rollout.started("11:00:01.000") + "\n"
        let bytes = Data(line.utf8)
        var follower = CodexRolloutFollower()
        follower.consume(bytes.prefix(40))
        #expect(follower.state.turn == nil)
        follower.consume(bytes.dropFirst(40))
        #expect(follower.state.turn == .running(since: Rollout.date("11:00:01.000")))
    }

    @Test func `reads a file from its end, then only what's appended`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "rollout.jsonl")
        // A big first turn whose start falls before the tail that's read.
        let filler = Rollout.agentMessage("11:00:02.000", String(repeating: "x", count: 1000))
        let lines =
            [Rollout.meta, Rollout.started("11:00:01.000")]
            + Array(repeating: filler, count: CodexRolloutFollower.initialTailSize / 1000 + 10)
            + [Rollout.completed("11:00:30.000")]
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: file)

        var follower = CodexRolloutFollower()
        follower.read(file)
        #expect(follower.state.meta?.originator == "codex-tui")
        #expect(follower.state.turn == .completed(at: Rollout.date("11:00:30.000")))

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Rollout.started("11:01:00.000") + "\n").utf8))
        try handle.close()
        follower.read(file)
        #expect(follower.state.turn == .running(since: Rollout.date("11:01:00.000")))
    }
}

struct CodexSessionTrackerTests {
    static let now = Rollout.date("12:00:00.000")

    static func thread(
        _ id: String, name: String? = "Fix the build", source: String = "cli", originator: String? = "codex-tui",
        updated: String = "11:59:00.000"
    ) -> CodexThreadRow {
        CodexThreadRow(
            id: id, rolloutPath: "/tmp/\(id).jsonl", cwd: "/code/app", name: name, title: "Please fix the build",
            source: source, originator: originator, gitBranch: "main", model: "gpt-6.1-sol", reasoningEffort: "high",
            createdAt: Rollout.date("11:00:00.000"), updatedAt: Rollout.date(updated))
    }

    static let escalation =
        #"tools.exec_command({cmd:"make",sandbox_permissions:"require_escalated",justification:"Build it"})"#

    static func waitingLog() -> CodexRolloutState {
        Rollout.state([
            Rollout.started("11:58:00.000"), Rollout.codeCall("11:59:00.000", id: "c", script: escalation),
        ])
    }

    static func process(_ pid: Int32, parent: Int32, name: String, started: String) -> ProcessEntry {
        ProcessEntry(pid: pid, parent: parent, startedAt: Rollout.date(started), name: name)
    }

    @Test func `a session no process has open is closed`() {
        let sessions = CodexSessionTracker.sessions(
            threads: [Self.thread("t1")], holders: [:], logs: ["t1": Self.waitingLog()], processes: [])
        #expect(sessions.first?.activity == .closed)
        #expect(sessions.first?.pid == nil)
    }

    @Test func `an escalation with no shell started since waits for approval`() {
        let processes = [
            Self.process(100, parent: 1, name: "codex", started: "10:00:00.000"),
            // A shell from before the call, and a helper that isn't a shell.
            Self.process(101, parent: 100, name: "zsh", started: "11:58:30.000"),
            Self.process(102, parent: 100, name: "node", started: "11:59:30.000"),
        ]
        let session = CodexSessionTracker.sessions(
            threads: [Self.thread("t1")], holders: ["t1": 100], logs: ["t1": Self.waitingLog()],
            processes: processes
        ).first
        #expect(session?.activity == .needsApproval("Build it"))
        #expect(session?.since == Rollout.date("11:59:00.000"))
    }

    @Test func `an escalation whose shell has started was approved and is working`() {
        let processes = [
            Self.process(100, parent: 1, name: "codex", started: "10:00:00.000"),
            Self.process(103, parent: 100, name: "zsh", started: "11:59:20.000"),
        ]
        let session = CodexSessionTracker.sessions(
            threads: [Self.thread("t1")], holders: ["t1": 100], logs: ["t1": Self.waitingLog()],
            processes: processes
        ).first
        #expect(session?.activity == .working(reviewing: false))
        #expect(session?.since == Rollout.date("11:58:00.000"))
    }

    @Test func `an escalation Codex's reviewer is looking at is working, not waiting`() {
        var reviewer = Rollout.state([Rollout.started("11:59:01.000")])
        reviewer.meta = CodexSessionMeta(parentThreadID: "t1", isApprovalReviewer: true)
        let threads = [Self.thread("t1"), Self.thread("g1", source: #"{"subagent":{"other":"guardian"}}"#)]
        let sessions = CodexSessionTracker.sessions(
            threads: threads, holders: ["t1": 100, "g1": 100], logs: ["t1": Self.waitingLog(), "g1": reviewer],
            processes: [])
        #expect(sessions.map(\.id) == ["t1"])
        #expect(sessions.first?.activity == .working(reviewing: true))
    }

    @Test func `maps turns to activities and sorts the most urgent first`() {
        let threads = [
            Self.thread("done"), Self.thread("idle"), Self.thread("stopped"), Self.thread("working"),
            Self.thread("asks"),
        ]
        let logs = [
            "done": Rollout.state([Rollout.started("11:50:00.000"), Rollout.completed("11:51:00.000")]),
            "stopped": Rollout.state([Rollout.started("11:50:00.000"), Rollout.aborted("11:52:00.000")]),
            "working": Rollout.state([Rollout.started("11:40:00.000")]),
            "asks": Rollout.state([
                Rollout.started("11:40:00.000"),
                Rollout.functionCall("11:41:00.000", id: "q", name: "request_user_input", arguments: "{}"),
            ]),
        ]
        let holders = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, Int32(100)) })
        let sessions = CodexSessionTracker.sessions(threads: threads, holders: holders, logs: logs, processes: [])
        #expect(sessions.map(\.id) == ["asks", "working", "done", "stopped", "idle"])
        #expect(sessions.map(\.activity) == [.needsInput, .working(reviewing: false), .finished, .stopped, .idle])
    }

    @Test func `shows the agents a session spawned that are working`() {
        let child = Self.thread(
            "c1", name: nil,
            source:
                #"{"subagent":{"thread_spawn":{"parent_thread_id":"t1","depth":1,"agent_nickname":"Franklin","agent_role":"explorer"}}}"#
        )
        let idleChild = Self.thread(
            "c2", source: #"{"subagent":{"thread_spawn":{"parent_thread_id":"t1","agent_nickname":"Locke"}}}"#)
        let sessions = CodexSessionTracker.sessions(
            threads: [Self.thread("t1"), child, idleChild], holders: ["t1": 1, "c1": 1, "c2": 1],
            logs: [
                "t1": Rollout.state([Rollout.started("11:00:00.000")]),
                "c1": Rollout.state([Rollout.started("11:00:05.000")]),
                "c2": Rollout.state([Rollout.started("11:00:05.000"), Rollout.completed("11:00:09.000")]),
            ], processes: [])
        #expect(sessions.map(\.id) == ["t1"])
        #expect(sessions.first?.workingSubagents == ["Franklin"])
    }

    @Test func `titles come from the name, then the request in the first prompt`() {
        #expect(CodexSessionTracker.title(of: Self.thread("a")) == "Fix the build")
        var attached = Self.thread("b", name: nil)
        attached.title =
            "# Files mentioned by the user:\n\n## CV.pdf: /x/CV.pdf\n\n## My request:\nFind me   a job\nplease"
        #expect(CodexSessionTracker.title(of: attached) == "Find me a job please")
        var untitled = Self.thread("c", name: nil)
        untitled.title = nil
        #expect(CodexSessionTracker.title(of: untitled) == "app")
    }

    @Test func `tells where a session runs from the client that started it`() {
        #expect(CodexSessionSurface(originator: "codex-tui", source: "cli") == .terminal)
        #expect(CodexSessionSurface(originator: "Codex Desktop", source: "vscode") == .desktop)
        #expect(CodexSessionSurface(originator: "codex_vscode", source: "vscode") == .ide)
        #expect(CodexSessionSurface(originator: "codex_exec", source: "exec") == .exec)
        #expect(CodexSessionSurface(originator: "monocode", source: "vscode") == .other("monocode"))
        #expect(CodexSessionSurface(originator: nil, source: "vscode") == .desktop)
        #expect(CodexSessionSurface(originator: nil, source: "exec") == .exec)
    }

    @Test func `the newest rate limits win`() {
        let older = Rollout.state([Rollout.tokenCount("11:00:00.000", tokens: 1)])
        var newer = Rollout.state([Rollout.tokenCount("11:30:00.000", tokens: 1)])
        newer.rateLimits?.primary?.usedPercent = 40
        let latest = CodexSessionTracker.latestRateLimits(in: [older, newer])
        #expect(latest?.0.primary?.usedPercent == 40)
        #expect(latest?.1 == Rollout.date("11:30:00.000"))
    }

    @Test func `links back into a session`() {
        #expect(
            CodexSessionLinks.appURL(threadID: "01a12aa7-afe3-7f40-80b6-f9500dc65e8f")?.absoluteString
                == "codex://threads/01a12aa7-afe3-7f40-80b6-f9500dc65e8f")
        #expect(CodexSessionLinks.appURL(threadID: "../settings") == nil)
        #expect(
            CodexSessionLinks.resumeCommand(threadID: "abc-1", cwd: "/code/my app")
                == "cd '/code/my app' && codex resume abc-1")
    }
}

struct CodexThreadIndexTests {
    /// A state database with the columns Codex 0.162 has that the widget reads, or only the required ones.
    static func makeDatabase(full: Bool) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "state_5.sqlite")
        var connection: OpaquePointer?
        try #require(sqlite3_open(url.path(percentEncoded: false), &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        let schema =
            full
            ? """
            CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL, source TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL,
            archived INTEGER NOT NULL DEFAULT 0, git_branch TEXT, model TEXT, reasoning_effort TEXT,
            updated_at_ms INTEGER, name TEXT, originator TEXT);
            INSERT INTO threads VALUES ('new', '/r/new.jsonl', 1000, 2000, 'cli', '/code/app', 'Fix it', 0, 'main',
            'gpt-6.1-sol', 'high', 2000500, 'Fix the build', 'codex-tui');
            INSERT INTO threads VALUES ('old', '/r/old.jsonl', 10, 20, 'vscode', '/code/app', 'Old', 0, NULL, NULL,
            NULL, 20000, NULL, NULL);
            INSERT INTO threads VALUES ('gone', '/r/gone.jsonl', 1000, 2000, 'cli', '/code/app', 'Archived', 1,
            NULL, NULL, NULL, 2000000, NULL, NULL);
            """
            : """
            CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, updated_at INTEGER NOT NULL,
            source TEXT NOT NULL);
            INSERT INTO threads VALUES ('new', '/r/new.jsonl', 2000, 'exec');
            """
        try #require(sqlite3_exec(connection, schema, nil, nil, nil) == SQLITE_OK)
        return url
    }

    @Test func `lists recent threads newest first, leaving out archived ones`() throws {
        let database = try Self.makeDatabase(full: true)
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }
        #expect(CodexThreadIndex.databaseURL(in: database.deletingLastPathComponent()) == database)

        let rows = try #require(
            CodexThreadIndex.threads(updatedSince: Date(timeIntervalSince1970: 1000), in: database))
        #expect(rows.map(\.id) == ["new"])
        let row = try #require(rows.first)
        #expect(row.name == "Fix the build")
        #expect(row.originator == "codex-tui")
        #expect(row.gitBranch == "main")
        #expect(row.updatedAt == Date(timeIntervalSince1970: 2000.5))
        #expect(row.createdAt == Date(timeIntervalSince1970: 1000))
    }

    @Test func `reads a database without the optional columns`() throws {
        let database = try Self.makeDatabase(full: false)
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }
        let rows = try #require(CodexThreadIndex.threads(updatedSince: .distantPast, in: database))
        #expect(rows.map(\.id) == ["new"])
        #expect(rows.first?.isExec == true)
        #expect(rows.first?.name == nil)
    }

    @Test func `a missing database reads as nil`() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/state_5.sqlite")
        #expect(CodexThreadIndex.threads(updatedSince: .distantPast, in: missing) == nil)
        #expect(CodexThreadIndex.databaseURL(in: missing.deletingLastPathComponent()) == nil)
    }

    @Test func `knows subagents and whose they are`() {
        let spawned = CodexThreadRow(
            id: "c", rolloutPath: "",
            source: #"{"subagent":{"thread_spawn":{"parent_thread_id":"p1","agent_nickname":"Ada"}}}"#,
            createdAt: .now, updatedAt: .now)
        #expect(spawned.isSubagent)
        #expect(spawned.parentThreadID == "p1")
        #expect(spawned.agentNickname == "Ada")
        let reviewer = CodexThreadRow(
            id: "g", rolloutPath: "", source: #"{"subagent":{"other":"guardian"}}"#, createdAt: .now, updatedAt: .now)
        #expect(reviewer.isSubagent)
        #expect(reviewer.parentThreadID == nil)
        #expect(!CodexThreadRow(id: "t", rolloutPath: "", createdAt: .now, updatedAt: .now).isSubagent)
    }
}

struct CodexSessionsSettingsTests {
    @Test func `defaults show the spotlight and the list`() {
        let settings = CodexSessionsSettings()
        #expect(settings.blocks.shownBlocks == [.spotlight, .sessions])
        #expect(settings.recentHours == 4)
        #expect(!settings.includesExec)
    }

    @Test func `missing, unknown and out-of-range options don't fail the configuration`() throws {
        let json = """
            {"recentHours": 0, "blocks": [{"block": "limits", "shown": true}, {"block": "future", "shown": true}],
             "blockOptions": {"sessions": {"maximumRows": 99}, "limits": {"reading": "sideways"}}}
            """
        let settings = try JSONDecoder().decode(CodexSessionsSettings.self, from: Data(json.utf8))
        #expect(settings.recentHours == 1)
        #expect(settings.blocks.shownBlocks == [.limits])
        #expect(settings.blocks.entries.map(\.block) == [.limits, .spotlight, .sessions])
        #expect(settings.blockOptions.sessions.maximumRows == CodexSessionListOptions.rowCountRange.upperBound)
        #expect(settings.blockOptions.limits.reading == .remaining)
        #expect(settings.blockOptions.spotlight == CodexSpotlightOptions())

        let empty = try JSONDecoder().decode(CodexSessionsSettings.self, from: Data("{}".utf8))
        #expect(empty == CodexSessionsSettings())
    }

    @Test func `a widget round-trips through JSON`() throws {
        var settings = CodexSessionsSettings(recentHours: 12, includesExec: true)
        settings.blocks.showOnly([.sessions, .limits])
        settings.blockOptions.spotlight.showsPlan = false
        let widget = WidgetInstance(settings: .codexSessions(settings))
        let decoded = try JSONDecoder().decode(WidgetInstance.self, from: JSONEncoder().encode(widget))
        #expect(decoded == widget)

        let bare = #"{"id":"\#(UUID().uuidString)","kind":"codexSessions","showsInSidePanel":true,"showsInBar":false}"#
        let withoutSettings = try JSONDecoder().decode(WidgetInstance.self, from: Data(bare.utf8))
        #expect(withoutSettings.settings == .codexSessions(CodexSessionsSettings()))
    }
}

struct ProcessTableSnapshotTests {
    @Test func `lists this process and finds descendants`() {
        let snapshot = ProcessTable.snapshot()
        let me = getpid()
        #expect(snapshot.contains { $0.pid == me && $0.parent == getppid() })

        let tree = [
            ProcessEntry(pid: 2, parent: 1, startedAt: .now, name: "codex"),
            ProcessEntry(pid: 3, parent: 2, startedAt: .now, name: "zsh"),
            ProcessEntry(pid: 4, parent: 3, startedAt: .now, name: "make"),
            ProcessEntry(pid: 5, parent: 1, startedAt: .now, name: "other"),
        ]
        #expect(Set(tree.descendants(of: 2).map(\.pid)) == [3, 4])
    }

    @Test func `lists the files a process has open under a folder`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lock = folder.appending(path: "thread.lock")
        try Data().write(to: lock)
        let handle = try FileHandle(forReadingFrom: lock)
        defer { try? handle.close() }
        // The temporary folder is reached through a link, /var to /private/var.
        let open = ProcessTable.openFiles(of: getpid(), withPrefix: folder.path(percentEncoded: false))
        #expect(open.contains { $0.hasSuffix("/thread.lock") })
    }
}
