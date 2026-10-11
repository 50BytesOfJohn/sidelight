import Foundation
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

        let cursorService = CursorChatsService()
        let sources = AgentSessionSources(
            claudeCode: ClaudeSessionsService(), codex: CodexSessionsService(), cursor: cursorService)
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
                Result<[CursorChat], CursorChatIndex.Failure>.failure(.unreadable),
                AgentSessionSources.State.unreadable(isStale: false), "Can't read sessions"
            ), (.failure(.unsupported), .unsupported, "Can't read sessions"),
            (.success([]), .found(open: nil), "No sessions in the last 24h"),
            (.failure(.noDatabase), .notFound, "No agents found"),
        ] {
            ControlledRead.result = result
            await cursorService.reload(generation: cursorService.reloadGeneration)
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
        await cursorService.reload(generation: cursorService.reloadGeneration)
        ControlledRead.result = .failure(.unreadable)
        await cursorService.reload(generation: cursorService.reloadGeneration)
        check(
            "Good data then unreadable retains rows and stale warning",
            cursorService.chats == [chat] && sources.state(of: .cursor) == .unreadable(isStale: true)
                && sources.state(of: .cursor).problem(of: .cursor)?.contains("out of date") == true)
        for healthyRows in [false, true] {
            for failure in [CursorChatIndex.Failure.unreadable, .unsupported] {
                ControlledRead.result = .failure(failure)
                await cursorService.reload(generation: cursorService.reloadGeneration)
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
        await cursorService.reload(generation: cursorService.reloadGeneration)
        check(
            "Repair clears warning and restores good source",
            sources.state(of: .cursor) == .found(open: nil) && cursorService.chats == [chat])
        cursorService.stop()

        ControlledRead.holdNext = true
        cursorService.start()
        await waitFor { ControlledRead.pending != nil }
        cursorService.stop()
        let new = CursorChat(id: "new-generation", updatedAt: now)
        ControlledRead.result = .success([new])
        cursorService.start()
        await waitFor { cursorService.chats == [new] }
        ControlledRead.pending?.resume(returning: .success([chat]))
        ControlledRead.pending = nil
        for _ in 0..<100 { await Task.yield() }
        check("Old read completing after restart cannot overwrite newer rows", cursorService.chats == [new])
        check("Old read cannot drop replacement task handle", cursorService.reloadTask == nil)
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
            cursorService.reloadTask != nil && cursorService.chats == [new])
        replacementRead?.resume(returning: .success([chat]))
        await waitFor { cursorService.chats == [chat] }
        check("Held replacement still publishes after old completion", cursorService.chats == [chat])
        cursorService.stop()
        print("RESULT \(checks) checks, \(failures) failures; all dispatch mocked")
        if failures != 0 { exit(1) }
    }

    // SwiftUI stores the chosen conditional branch. Inspect the actual production leaf,
    // rather than duplicating its branching conditions in a test implementation.
    static func contentLeaf(_ value: Any, depth: Int = 0) -> (message: AgentSessionsMessage?, list: AgentSessionList?) {
        if let message = value as? AgentSessionsMessage { return (message, nil) }
        if let list = value as? AgentSessionList { return (nil, list) }
        guard depth < 20 else { return (nil, nil) }
        for child in Mirror(reflecting: value).children {
            let found = contentLeaf(child.value, depth: depth + 1)
            if found.message != nil || found.list != nil { return found }
        }
        return (nil, nil)
    }
}
