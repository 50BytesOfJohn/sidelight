import Foundation
import SQLite3
import SidelightCore
import SwiftUI

@main
struct ContractHarness {
    static func main() async throws {
        var checks = 0
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            checks += 1
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        func waitFor(_ condition: () -> Bool) async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !condition(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            precondition(condition(), "Controlled read did not reach its barrier")
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = MockWorkspace.shared
        let directory = URL(filePath: FileManager.default.currentDirectoryPath).appending(
            path: "build/agent-sessions-contract-folders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appending(path: "Demo Project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = directory.appending(path: "plain-file")
        try Data().write(to: file)

        for (path, title) in [
            (folder.path, "Open Project in Cursor"), (directory.appending(path: "deleted").path, "Open Cursor"),
            (file.path, "Open Cursor"), ("", "Open Cursor"), ("/", "Open Cursor"), (nil, "Open Cursor"),
        ] {
            let chat = CursorChat(id: "synthetic", workspacePath: path, updatedAt: now)
            let route = AgentSessionOpener.route(for: AgentSession(chat))
            check(
                "Cursor route for \(path?.isEmpty == true ? "empty" : path.map { URL(filePath: $0).lastPathComponent } ?? "absent")",
                route?.kind == .project && route?.title == title && route?.help.contains("one particular chat") == true)
            workspace.events = []
            check("Cursor mocked execution succeeds", await AgentSessionOpener.openProject(of: chat))
            check(
                "Cursor route and dispatch agree",
                workspace.events
                    == (title == "Open Cursor"
                        ? ["application:\(AgentSessionOpener.cursorBundleID).app"] : ["folder:Demo Project"]))
        }
        let chat = CursorChat(id: "synthetic", workspacePath: folder.path, updatedAt: now)
        workspace.folderSucceeds = false
        workspace.events = []
        check("Cursor failed folder handoff falls back to app", await AgentSessionOpener.openProject(of: chat))
        check(
            "Cursor fallback dispatch sequence",
            workspace.events == ["folder:Demo Project", "application:\(AgentSessionOpener.cursorBundleID).app"])
        workspace.appSucceeds = false
        check("Cursor failed folder and app returns failure", await !AgentSessionOpener.openProject(of: chat))
        workspace.folderSucceeds = true
        workspace.appSucceeds = true
        try FileManager.default.removeItem(at: folder)
        workspace.events = []
        check(
            "Cursor deleted folder immediately changes route",
            AgentSessionOpener.route(for: AgentSession(chat))?.title == "Open Cursor")
        _ = await AgentSessionOpener.openProject(of: chat)
        check(
            "Cursor deleted folder executes app fallback",
            workspace.events.count == 1 && workspace.events.first?.hasPrefix("application:") == true)
        workspace.installed = []
        let absentExecution = await AgentSessionOpener.openProject(of: chat)
        check(
            "Cursor absent app has no route or execution",
            AgentSessionOpener.route(for: AgentSession(chat)) == nil && !absentExecution)
        workspace.installed = [AgentSessionOpener.cursorBundleID, CodexSessionOpener.appBundleID]

        var codex = CodexSession(
            id: "synthetic", title: "Actionable Codex", surface: .terminal, activity: .idle, since: now, pid: 99)
        MockHost.host = nil
        check(
            "Codex hostless PID uses truthful app route",
            AgentSessionOpener.route(for: AgentSession(codex))?.title == "Open in Codex")
        workspace.events = []
        _ = await CodexSessionOpener.bringForward(codex)
        check("Codex hostless execution agrees via mock only", workspace.events == ["url:codex"])
        workspace.installed.remove(CodexSessionOpener.appBundleID)
        check("Codex hostless missing app unavailable", AgentSessionOpener.route(for: AgentSession(codex)) == nil)
        workspace.installed.insert(CodexSessionOpener.appBundleID)
        MockHost.host = MockApplication(bundleIdentifier: CodexSessionOpener.appBundleID, localizedName: "Codex")
        check(
            "Codex host itself uses session route", AgentSessionOpener.route(for: AgentSession(codex))?.kind == .session
        )
        for (id, name, surface, text) in [
            (TerminalFocusScript.terminalBundleID, "Terminal", CodexSessionSurface.terminal, "or else Terminal"),
            ("com.synthetic.editor", "Editor", .ide, "window with this session's folder"),
            ("com.synthetic.host", "Harness Host", .desktop, "may not show the session itself"),
        ] {
            MockHost.host = MockApplication(bundleIdentifier: id, localizedName: name)
            codex.surface = surface
            codex.cwd = folder.path
            let route = AgentSessionOpener.route(for: AgentSession(codex))
            MockHost.events = []
            workspace.events = []
            _ = await CodexSessionOpener.bringForward(codex)
            check(
                "Codex \(name) route and help",
                route?.kind == .host && route?.title == "Show \(name)" && route?.help.contains(text) == true)
            check(
                "Codex \(name) dispatch agrees",
                MockHost.events == ["\(name):\(surface == .ide):\(folder.path)"] && workspace.events.isEmpty)
        }
        MockHost.host = MockApplication(bundleIdentifier: "com.synthetic.editor", localizedName: "Editor")
        for source in [
            AgentSession(
                CodexSession(
                    id: "synthetic", title: "Editor Codex", cwd: folder.path, surface: .ide, activity: .idle,
                    since: now, pid: 99)),
            AgentSession(
                ClaudeSession(
                    id: "synthetic", title: "Editor Claude", surface: .vscode, activity: .idle, since: now, pid: 99,
                    cwd: folder.path)),
        ] {
            let help = AgentSessionOpener.route(for: source)?.help ?? ""
            check(
                "\(source.provider) editor help discloses app fallback when folder handoff fails",
                help.contains("or else") || help.contains("or opens") || help.contains("may not"))
        }
        for cwd: String? in [nil, ""] {
            for source in [
                AgentSession(
                    CodexSession(
                        id: "synthetic", title: "Editor Codex", cwd: cwd, surface: .ide, activity: .idle, since: now,
                        pid: 99)),
                AgentSession(
                    ClaudeSession(
                        id: "synthetic", title: "Editor Claude", surface: .vscode, activity: .idle, since: now, pid: 99,
                        cwd: cwd)),
            ] {
                let route = AgentSessionOpener.route(for: source)
                check(
                    "\(source.provider) editor \(cwd == nil ? "absent" : "empty") cwd uses generic host help",
                    route?.kind == .host && route?.title == "Show Editor"
                        && route?.help.contains("may not show the session itself") == true
                        && route?.help.contains("session's folder") == false)
            }
        }
        MockHost.host = nil
        let claude = ClaudeSession(id: "synthetic", title: "Unavailable Claude", activity: .idle, since: now, pid: 99)
        check("Claude hostless PID unavailable", AgentSessionOpener.route(for: AgentSession(claude)) == nil)
        check(
            "Both Claude widget mappings name unknown",
            ClaudeSession.Activity.unknown.title == "Status unknown"
                && AgentSession.Status.unknown.title == "Status unknown"
                && ClaudeSession.Activity.unknown.systemImage == AgentSession.Status.unknown.systemImage)

        codex.pid = nil
        codex.since = now.addingTimeInterval(-1)
        let actionable = AgentSession(codex)
        let cursor = AgentSession(CursorChat(id: "synthetic", name: "Newer Cursor", updatedAt: now))
        let closed = AgentSession(ClaudeSession(id: "synthetic", title: "Closed Claude", activity: .closed, since: now))
        for (name, sessions, expected) in [
            ("newer Cursor before actionable Codex", AgentSession.merged([[cursor, actionable]]), false),
            ("closed Claude first", [closed, actionable], false),
            ("hostless Claude first", [AgentSession(claude), actionable], false),
            ("actionable first", [actionable, cursor], true), ("Cursor only", [cursor], false),
            ("no sessions", [], false),
        ] {
            let glance = AgentSessionsGlance(
                sessions: sessions, problems: ["Synthetic source warning"], isBar: true, now: now)
            let action = glance.action
            check(
                "Bar \(name) target",
                (action != nil) == expected && (action == nil || action?.session.id == sessions.first?.id))
            let help = glance.helpText(action)
            check(
                "Bar \(name) help identity",
                help.contains("Synthetic source warning")
                    && (expected
                        ? help.contains("Click: Open in Codex, for Actionable Codex") : !help.contains("Click:"))
            )
        }

        // The actual generic index with its read injected; the database folder is absent, so no watcher is made.
        let unwatched = directory.appending(path: "no-watched-folder/state.db")
        let cursorService = CursorChatsService(name: "Cursor", database: unwatched, log: Log.cursor) { _, _ in
            await ControlledRead.read()
        }
        let openCodeService = OpenCodeSessionsService(name: "OpenCode", database: unwatched, log: Log.openCode) {
            database, _ in await ControlledOpenCodeRead.read(database)
        }
        let sources = AgentSessionSources(
            claudeCode: ClaudeSessionsService(), codex: CodexSessionsService(), cursor: cursorService,
            openCode: openCodeService)
        check("Cursor before initial read is loading", sources.state(of: .cursor) == .reading)
        let loadingContent = AgentSessionsContent(
            sources: sources, settings: AgentSessionsSettings(providers: [.cursor]), sessions: [], layout: .regular,
            now: now)
        check(
            "Cursor loading uses actual reading branch",
            contentLeaf(loadingContent.body).message?.title == "Reading sessions…")
        cursorService.isEnabled = true
        // Direct publication exercises actual result handling without depending on FSEvents.
        for (result, state, title) in [
            (
                Result<[CursorChat], SessionIndexFailure>.failure(.unreadable),
                AgentSessionSources.State.unreadable(isStale: false), "Can't read sessions"
            ), (.failure(.unsupported), .unsupported, "Can't read sessions"),
            (.success([]), .found(open: nil), "No sessions in the last 24h"),
            (.failure(.noDatabase), .notFound, "No agents found"),
        ] {
            ControlledRead.result = result
            await cursorService.reloadNow()
            check("Cursor completed read state \(title)", sources.state(of: .cursor) == state)
            let content = AgentSessionsContent(
                sources: sources, settings: AgentSessionsSettings(providers: [.cursor]), sessions: [], layout: .regular,
                now: now)
            let leaf = contentLeaf(content.body)
            check(
                "Cursor actual content branch \(title)",
                title.hasPrefix("No sessions") ? leaf.list != nil : leaf.message?.title == title)
        }
        ControlledRead.result = .success([chat])
        await cursorService.reloadNow()
        ControlledRead.result = .failure(.unreadable)
        await cursorService.reloadNow()
        check(
            "Good data then unreadable retains rows and stale warning",
            cursorService.sessions == [chat] && sources.state(of: .cursor) == .unreadable(isStale: true)
                && sources.state(of: .cursor).problem(of: .cursor)?.contains("out of date") == true)
        for healthyRows in [false, true] {
            for failure in [CursorChatIndex.Failure.unreadable, .unsupported] {
                ControlledRead.result = .failure(failure)
                await cursorService.reloadNow()
                let healthy = healthyRows ? [actionable] : []
                let content = AgentSessionsContent(
                    sources: sources, settings: AgentSessionsSettings(providers: [.codex, .cursor]), sessions: healthy,
                    layout: .regular, now: now)
                let leaf = contentLeaf(content.body)
                check(
                    "Mixed healthy \(healthyRows ? "rows" : "empty") plus \(failure)",
                    leaf.list?.sessions == healthy && leaf.list?.problems.count == 1 && leaf.message == nil)
            }
        }
        ControlledRead.result = .success([chat])
        await cursorService.reloadNow()
        check(
            "Repair clears warning and restores good source",
            sources.state(of: .cursor) == .found(open: nil) && cursorService.sessions == [chat])
        cursorService.stop()

        ControlledRead.holdNext = true
        cursorService.start()
        await waitFor { ControlledRead.pending != nil }
        cursorService.stop()
        let new = CursorChat(id: "new-generation", updatedAt: now)
        ControlledRead.result = .success([new])
        cursorService.start()
        await waitFor { cursorService.sessions == [new] }
        ControlledRead.pending?.resume(returning: .success([chat]))
        ControlledRead.pending = nil
        for _ in 0..<100 { await Task.yield() }
        check("Old read completing after restart cannot overwrite newer rows", cursorService.sessions == [new])
        check("Old read cannot drop replacement task handle", !cursorService.reload.isActive)
        cursorService.stop()
        ControlledRead.holdNext = true
        cursorService.start()
        await waitFor { ControlledRead.pending != nil }
        let oldRead = ControlledRead.pending
        ControlledRead.pending = nil
        cursorService.stop()
        ControlledRead.holdNext = true
        cursorService.start()
        await waitFor { ControlledRead.pending != nil }
        let replacementRead = ControlledRead.pending
        ControlledRead.pending = nil
        oldRead?.resume(returning: .success([CursorChat(id: "stale", updatedAt: now)]))
        for _ in 0..<100 { await Task.yield() }
        check(
            "Old completion preserves active replacement handle",
            cursorService.reload.isActive && cursorService.sessions == [new])
        replacementRead?.resume(returning: .success([chat]))
        await waitFor { cursorService.sessions == [chat] }
        check("Held replacement still publishes after old completion", cursorService.sessions == [chat])
        cursorService.stop()
        // OpenCode publication uses the current production service body with only its async read controlled.
        check("OpenCode initial source is reading", sources.state(of: .openCode) == .reading)
        openCodeService.isEnabled = true
        for (result, state) in [
            (
                Result<[OpenCodeSession], SessionIndexFailure>.failure(.unreadable),
                AgentSessionSources.State.unreadable(isStale: false)
            ),
            (.failure(.unsupported), .unsupported), (.failure(.noDatabase), .notFound),
            (.success([]), .found(open: nil)),
        ] {
            ControlledOpenCodeRead.result = result
            await openCodeService.reloadNow()
            check("OpenCode completed source state \(state)", sources.state(of: .openCode) == state)
            let content = AgentSessionsContent(
                sources: sources, settings: AgentSessionsSettings(providers: [.openCode]), sessions: [],
                layout: .regular, now: now)
            let leaf = contentLeaf(content.body)
            check(
                "OpenCode source chooses actual content branch \(state)",
                state == .found(open: nil) ? leaf.list != nil : leaf.message != nil)
        }
        let openCode = OpenCodeSession(
            id: "ses_fixture", title: "Synthetic OpenCode", directory: directory.path, createdAt: now, updatedAt: now)
        ControlledOpenCodeRead.result = .success([openCode])
        await openCodeService.reloadNow()
        ControlledOpenCodeRead.result = .failure(.unreadable)
        await openCodeService.reloadNow()
        check(
            "OpenCode unreadable preserves stale rows",
            openCodeService.sessions == [openCode] && sources.state(of: .openCode) == .unreadable(isStale: true))
        check(
            "OpenCode stale warning is explicit",
            sources.state(of: .openCode).problem(of: .openCode)?.contains("out of date") == true)
        check(
            "OpenCode adaptation through shared source",
            sources.sessions(for: AgentSessionsSettings(providers: [.openCode])).map(\.id) == [
                AgentSession(openCode).id
            ])
        ControlledOpenCodeRead.result = .success([openCode])
        await openCodeService.reloadNow()
        check("OpenCode recovery clears warning", sources.state(of: .openCode) == .found(open: nil))
        ControlledOpenCodeRead.result = .failure(.unsupported)
        await openCodeService.reloadNow()
        check("OpenCode incompatible replacement clears stale rows", openCodeService.sessions.isEmpty)
        ControlledOpenCodeRead.result = .success([openCode])
        await openCodeService.reloadNow()
        ControlledOpenCodeRead.result = .failure(.noDatabase)
        await openCodeService.reloadNow()
        check(
            "OpenCode removed source clears rows and starts missing sweep",
            openCodeService.sessions.isEmpty && openCodeService.sweep.isRunning)
        openCodeService.stop()
        check(
            "OpenCode stop cancels read and sweep",
            !openCodeService.reload.isActive && !openCodeService.sweep.isRunning && openCodeService.watcher == nil)
        ControlledOpenCodeRead.holdNext = true
        openCodeService.start()
        openCodeService.start()
        await waitFor { ControlledOpenCodeRead.pending != nil }
        let oldOpenCodeRead = ControlledOpenCodeRead.pending
        ControlledOpenCodeRead.pending = nil
        openCodeService.stop()
        ControlledOpenCodeRead.holdNext = true
        openCodeService.start()
        await waitFor { ControlledOpenCodeRead.pending != nil }
        let replacementOpenCodeRead = ControlledOpenCodeRead.pending
        ControlledOpenCodeRead.pending = nil
        oldOpenCodeRead?.resume(returning: .success([openCode]))
        for _ in 0..<100 { await Task.yield() }
        check(
            "OpenCode old completion preserves replacement handle and does not publish",
            openCodeService.reload.isActive && openCodeService.sessions.isEmpty)
        replacementOpenCodeRead?.resume(returning: .success([openCode]))
        await waitFor { openCodeService.sessions == [openCode] }
        check(
            "OpenCode replacement generation publishes",
            openCodeService.hasLoaded && openCodeService.sessions == [openCode])
        openCodeService.stop()
        openCodeService.stop()

        // Former command tests now assert conservative refusal for the same hostile inputs.
        // Owned executable markers are never run; their presence must not change OpenCode policy.
        let home = URL.homeDirectory
        guard home.path.contains("/build/agent-sessions-harness/") else { fatalError("Isolated harness home required") }
        let localBin = home.appending(path: ".local/bin")
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        let executable = localBin.appending(path: "opencode2")
        let ambiguousV1 = localBin.appending(path: "opencode")
        defer {
            try? FileManager.default.removeItem(at: executable)
            try? FileManager.default.removeItem(at: ambiguousV1)
        }
        func assertInert(_ name: String, _ value: OpenCodeSession) {
            let session = AgentSession(value)
            workspace.events = []
            MockHost.events = []
            MockHost.writes = []
            MockProcessRunner.scripts = []
            MockSound.beeps = 0
            AgentSessionOpener.open(session)
            AgentSessionOpener.copyResumeCommand(of: session)
            check(
                "OpenCode \(name) no route, command, dispatch or resume copy",
                AgentSessionOpener.route(for: session) == nil
                    && !AgentSessionOpener.canCopyResumeCommand(of: session)
                    && workspace.events.isEmpty && MockHost.events.isEmpty
                    && MockProcessRunner.scripts.isEmpty && MockHost.writes.isEmpty && MockSound.beeps == 1)
            let copies = AgentSessionOpener.contextCopies(of: session)
            check(
                "OpenCode \(name) exactly two named plaintext copies",
                copies.map(\.title) == ["Copy Session ID", "Copy Folder Path"]
                    && copies.map(\.systemImage) == ["number", "folder"]
                    && copies.map(\.text) == [value.id, value.directory])
            for copy in copies { AgentSessionOpener.copy(copy) }
            check(
                "OpenCode \(name) clipboard writes are verbatim data",
                MockHost.writes == [value.id, value.directory] && MockHost.copied == value.directory
                    && workspace.events.isEmpty && MockHost.events.isEmpty && MockProcessRunner.scripts.isEmpty)
        }
        assertInert("no install", openCode)
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: ambiguousV1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ambiguousV1.path)
        assertInert("ambiguous V1 only", openCode)
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        assertInert("named V2 executable present", openCode)
        for (name, variable, value) in [
            ("wrong store", "OPENCODE_DB", home.appending(path: "store-B.db").path),
            ("default environment drift", "XDG_DATA_HOME", home.appending(path: "other-data").path),
            ("underlying V1 binary override", "OPENCODE_BIN_PATH", ambiguousV1.path),
        ] {
            let original = getenv(variable).map { String(cString: $0) }
            setenv(variable, value, 1)
            assertInert(name, openCode)
            if let original { setenv(variable, original, 1) } else { unsetenv(variable) }
        }
        var unavailable = openCode
        for (name, path) in [
            ("file folder", file.path), ("deleted folder", directory.appending(path: "absent").path),
            ("empty folder", ""), ("root folder", "/"),
            ("quoted shell syntax as data", "/synthetic/space ' $() `echo nope` \\\" ; folder"),
            ("newline folder", "/synthetic/line\nbreak"),
            ("CR folder", "/synthetic/line\rbreak"), ("NUL folder", "/synthetic/\u{0}folder"),
            ("ESC folder", "/synthetic/\u{1b}folder"), ("Unicode separator", "/synthetic/\u{2028}folder"),
        ] {
            unavailable.directory = path
            assertInert(name, unavailable)
        }
        for id in [
            "ses_a", "ses_Z19_", "ses_" + String(repeating: "x", count: 96),
            "", "ses_", "sess_a", "ses_ä", "ses_x;touch nope", "ses_x\n", "ses_x\r", "ses_x\u{0}",
            "ses_" + String(repeating: "x", count: 97),
        ] {
            // Never include hostile data in a diagnostic log.
            unavailable = OpenCodeSession(id: id, directory: directory.path, createdAt: now, updatedAt: now)
            assertInert("ID adversary", unavailable)
        }
        let unavailableHelp =
            "Can't be opened from here: Sidelight can't tell which OpenCode would show this session. "
            + "Right-click to copy its session ID or folder."
        let row = AgentSessionRow(session: AgentSession(openCode), isCompact: false, now: now)
        check(
            "OpenCode row help describes metadata and identical unavailable policy",
            AgentSessionOpener.unavailableHelp(for: AgentSession(openCode)) == unavailableHelp
                && row.help(nil) == "OpenCode's session list doesn't say whether a session is working or waiting\n"
                    + unavailableHelp
        )
        for isBar in [true, false] {
            let glance = AgentSessionsGlance(
                sessions: [AgentSession(openCode), actionable], problems: ["Synthetic source warning"],
                isBar: isBar, now: now)
            check(
                "OpenCode \(isBar ? "bar" : "minimal") remains informational with top identity",
                glance.action == nil && !glance.helpText(glance.action).contains("Click:")
                    && glance.helpText(nil).hasPrefix("OpenCode · \(AgentSession(openCode).title): Updated")
                    && glance.helpText(nil).contains("Synthetic source warning"))
        }
        check(
            "Existing Claude unavailable help unchanged",
            AgentSessionOpener.unavailableHelp(for: AgentSession(claude))
                == "Can't be opened from here. Right-click to copy the command that resumes it.")
        check(
            "Existing Codex unavailable help unchanged",
            AgentSessionOpener.unavailableHelp(for: actionable)
                == "Can't be opened from here. Right-click to copy the command that resumes it.")
        check(
            "Existing Cursor unavailable help unchanged",
            AgentSessionOpener.unavailableHelp(for: cursor) == "Can't be opened from here")
        check(
            "Other providers acquire no context-copy menus",
            [AgentSession(claude), actionable, cursor].allSatisfy { AgentSessionOpener.contextCopies(of: $0).isEmpty })
        if let db = OpenCodeSessionsService.openCode().database {
            try FileManager.default.createDirectory(
                at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
            var writer: OpaquePointer?
            precondition(sqlite3_open(db.path, &writer) == SQLITE_OK)
            defer {
                sqlite3_close(writer)
                try? FileManager.default.removeItem(at: db)
            }
            precondition(
                sqlite3_exec(
                    writer,
                    "CREATE TABLE IF NOT EXISTS session_v2(id TEXT, parent_id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER)",
                    nil, nil, nil) == SQLITE_OK)
            precondition(
                sqlite3_exec(
                    writer,
                    "DELETE FROM session_v2; INSERT INTO session_v2 VALUES ('ses_fixture', NULL, '/synthetic/repo', NULL, 1800000000000, 1800000000000, NULL)",
                    nil, nil, nil) == SQLITE_OK)
            check(
                "OpenCode selected ID initially exists in source store",
                (try? OpenCodeSessionIndex.sessions(updatedSince: .distantPast, in: db).get().map(\.id)) == [
                    "ses_fixture"
                ])
            precondition(sqlite3_exec(writer, "DELETE FROM session_v2", nil, nil, nil) == SQLITE_OK)
            check(
                "OpenCode deleted ID is absent before click",
                (try? OpenCodeSessionIndex.sessions(updatedSince: .distantPast, in: db).get().isEmpty) == true)
        }
        assertInert("deleted ID / detached model", openCode)
        assertInert("stale last-successful-read model", openCodeService.sessions.first ?? openCode)
        try FileManager.default.removeItem(at: executable)
        assertInert("executable removed before click", openCode)
        check(
            "Released three-agent summary stays explicit",
            AgentSessionsSettings(providers: [.codex, .claudeCode, .cursor]).summary.hasPrefix("All agents") == false)
        check("New four-agent summary is all agents", AgentSessionsSettings().summary.hasPrefix("All agents"))
        let overview = WidgetMetadata.agentSessions.summary.lowercased()
        check(
            "OpenCode overview distinguishes metadata/context copies from opening",
            overview.contains("opencode") && overview.contains("cop")
                && (overview.contains("metadata") || overview.contains("aren't opened")
                    || overview.contains("can't be opened") || overview.contains("not opened"))
        )
        print("RESULT \(checks) checks, \(failures) failures; all dispatch mocked")
        if failures != 0 { exit(1) }
    }

    // SwiftUI stores the chosen conditional branch. Inspect the actual production leaf,
    // rather than duplicating its branching conditions in a test implementation.
    static func contentLeaf(_ value: Any, depth: Int = 0) -> (message: WidgetMessage?, list: AgentSessionList?) {
        if let message = value as? WidgetMessage { return (message, nil) }
        if let list = value as? AgentSessionList { return (nil, list) }
        guard depth < 20 else { return (nil, nil) }
        for child in Mirror(reflecting: value).children {
            let found = contentLeaf(child.value, depth: depth + 1)
            if found.message != nil || found.list != nil { return found }
        }
        return (nil, nil)
    }
}
