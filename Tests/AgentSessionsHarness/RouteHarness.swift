import AppKit
import Foundation
import SidelightCore

// Exercise route decisions with fabricated sources and an inert process. Never dispatch URLs or open sessions.
@main
struct RouteHarness {
    static func main() throws {
        let home = URL.homeDirectory
        guard home.path.contains("/build/agent-sessions-fixture-home") else { fatalError("Fixture home required") }
        let pids = try JSONDecoder().decode(
            [Int32].self, from: Data(contentsOf: home.appending(path: "fixture-processes.json")))
        guard let pid = pids.last else { fatalError("Inert host required") }
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        let closedClaude = AgentSession(ClaudeSession(id: "fixture", title: "Fixture", activity: .closed, since: .now))
        check("closed CLI Claude offers no session opening route", AgentSessionOpener.route(for: closedClaude) == nil)
        check("closed CLI Claude can copy a resume command", AgentSessionOpener.canCopyResumeCommand(of: closedClaude))
        let cursor = AgentSession(
            CursorChat(
                id: "fixture-local-composer", workspacePath: home.appending(path: "Demo Project").path, updatedAt: .now)
        )
        check(
            "Cursor local composer never offers a CLI resume command",
            !AgentSessionOpener.canCopyResumeCommand(of: cursor))
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentSessionOpener.cursorBundleID) != nil {
            check("Cursor is explicitly a project route", AgentSessionOpener.route(for: cursor)?.kind == .project)
            check(
                "Cursor names project opening", AgentSessionOpener.route(for: cursor)?.title == "Open Project in Cursor"
            )
        } else {
            print("NOT TESTED Cursor app registration unavailable")
        }
        if CodexSessionOpener.isAppInstalled {
            let codex = AgentSession(
                CodexSession(
                    id: "fixture", title: "Fixture", surface: .terminal, activity: .working(reviewing: false),
                    since: .now, pid: pid))
            check("inert Codex host has no regular app ancestor", SessionHost.app(of: pid) == nil)
            let route = AgentSessionOpener.route(for: codex)
            print("OBSERVED Codex fallback route title: \(route?.title ?? "none")")
            check("Codex without a host labels its Desktop fallback honestly", route?.title == "Open in Codex")
        } else {
            print("NOT TESTED Codex app registration unavailable")
        }
        print("RESULT \(failures) failures; no routes dispatched")
        if failures != 0 { exit(1) }
    }
}
