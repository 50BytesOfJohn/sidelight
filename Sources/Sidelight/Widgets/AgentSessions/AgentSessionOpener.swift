import AppKit
import SidelightCore

/// Opens any agent's session the way that agent allows, and says beforehand what a click will do, so a row never
/// promises more than it can. What a row says and what a click does come from the same decision:
///
/// - Claude Code and Codex sessions open in the agent's desktop app through its own link, or bring forward the
///   terminal or editor running them, at the session where ``SessionHost`` can, as ``ClaudeSessionOpener`` and
///   ``CodexSessionOpener`` decide.
/// - Cursor can't be asked from outside to open one of its chats, so a Cursor chat asks Cursor to open its project
///   folder, or just opens Cursor, and says so.
/// - OpenCode sessions aren't opened. No outside link to one session in its desktop app is known, and resuming one
///   with its CLI can reach a server that keeps another database, or start a new session in its place: nothing
///   Sidelight reads says which. Their ID and folder can be copied instead, as plain text.
enum AgentSessionOpener {
    /// What a click on a session does.
    struct Route: Equatable {
        enum Kind: Equatable {
            /// Opens the session itself, in the agent's app.
            case session
            /// Brings forward the app running the session: at its tab or window where that app allows, else the app.
            case host
            /// Opens Cursor, with the chat's project where there is one, not the chat.
            case project
        }

        let kind: Kind
        /// A menu item's title: `Open in Codex`, `Show Terminal`.
        let title: String
        /// What happens, for the tooltip and VoiceOver.
        let help: String
    }

    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"
    /// Terminals ``SessionHost`` can ask for a session's own tab.
    private static let scriptableTerminals = [
        TerminalFocusScript.terminalBundleID, TerminalFocusScript.iTermBundleID, TerminalFocusScript.ghosttyBundleID,
    ]

    /// `nil` when nothing can be opened, such as a closed Claude Code session from a terminal.
    static func route(for session: AgentSession) -> Route? {
        switch session.source {
        case .claudeCode(let claude):
            switch ClaudeSessionOpener.destination(of: claude) {
            case .app:
                return Route(kind: .session, title: "Open in Claude", help: "Opens this session in the Claude app")
            case .host(let app, _):
                return hostRoute(app, opensFolder: claude.surface == .vscode && claude.cwd?.isEmpty == false)
            case nil: return nil
            }
        case .codex(let codex):
            switch CodexSessionOpener.destination(of: codex) {
            case .app:
                return Route(kind: .session, title: "Open in Codex", help: "Opens this session in the Codex app")
            case .host(let app, _):
                return hostRoute(app, opensFolder: codex.surface == .ide && codex.cwd?.isEmpty == false)
            case nil: return nil
            }
        case .cursor(let chat):
            guard cursorAppURL != nil else { return nil }
            let noChat = "Cursor can't be asked to open one particular chat."
            if let project = chat.project, projectFolder(of: chat) != nil {
                // Handing Cursor a folder is a request: Cursor decides what it shows, and may show its Agents
                // window rather than the project.
                return Route(
                    kind: .project, title: "Open Project in Cursor",
                    help: "Asks Cursor to open \(project), or opens Cursor. \(noChat) Look for it in Cursor's chats.")
            }
            if let project = chat.project {
                return Route(
                    kind: .project, title: "Open Cursor",
                    help: "Opens Cursor. \(project)'s folder isn't on this Mac anymore, and \(noChat.lowercasedFirst)")
            }
            return Route(kind: .project, title: "Open Cursor", help: "Opens Cursor. \(noChat)")
        case .openCode: return nil
        }
    }

    /// Bringing forward the app a session runs in, in what that app allows: a terminal's tab, an editor's window.
    private static func hostRoute(_ app: NSRunningApplication, opensFolder: Bool) -> Route {
        let name = app.localizedName ?? "App"
        let help =
            if opensFolder {
                "Asks \(name) for the window with this session's folder, or else brings \(name) forward"
            } else if let bundleID = app.bundleIdentifier, scriptableTerminals.contains(bundleID) {
                "Brings forward the \(name) tab running this session, or else \(name)"
            } else {
                "Brings \(name) forward, where this session runs. It may not show the session itself."
            }
        return Route(kind: .host, title: "Show \(name)", help: help)
    }

    /// Beeps when nothing could be brought forward, such as a session running in tmux.
    static func open(_ session: AgentSession) {
        switch session.source {
        case .claudeCode(let claude): ClaudeSessionOpener.open(claude)
        case .codex(let codex): CodexSessionOpener.open(codex)
        case .cursor(let chat):
            Task {
                if await !openProject(of: chat) { NSSound.beep() }
            }
        case .openCode: NSSound.beep()
        }
    }

    /// The command that picks the session up again in a terminal, for agents that have one.
    static func canCopyResumeCommand(of session: AgentSession) -> Bool {
        switch session.source {
        case .claudeCode, .codex: true
        // `agent --resume` continues a Cursor CLI chat; nothing says an editor chat's ID is one.
        case .cursor: false
        // Nothing says `opencode --session` reaches the database this session was read from.
        case .openCode: false
        }
    }

    static func copyResumeCommand(of session: AgentSession) {
        switch session.source {
        case .claudeCode(let claude): ClaudeSessionOpener.copyResumeCommand(of: claude)
        case .codex(let codex): CodexSessionOpener.copyResumeCommand(of: codex)
        case .cursor, .openCode: break
        }
    }

    // MARK: Cursor

    private static var cursorAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: cursorBundleID)
    }

    /// The chat's project folder, when it's still a folder on this Mac. A chat without a project, or with an empty
    /// or root path, has none.
    private static func projectFolder(of chat: CursorChat) -> URL? {
        guard chat.project != nil, let path = chat.workspacePath else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// Hands Cursor the chat's folder, or else opens Cursor itself, as the route says.
    private static func openProject(of chat: CursorChat) async -> Bool {
        guard let appURL = cursorAppURL else { return false }
        if let folder = projectFolder(of: chat),
            (try? await NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: .init())) != nil
        {
            return true
        }
        return (try? await NSWorkspace.shared.openApplication(at: appURL, configuration: .init())) != nil
    }

    // MARK: Context

    /// Plain text about a session to paste elsewhere, for sessions that can't be opened or resumed from here.
    struct ContextCopy: Identifiable {
        /// A menu item's title: `Copy Session ID`.
        let title: String
        let systemImage: String
        let text: String
        var id: String { title }
    }

    static func contextCopies(of session: AgentSession) -> [ContextCopy] {
        switch session.source {
        case .openCode(let openCode):
            [
                ContextCopy(title: "Copy Session ID", systemImage: "number", text: openCode.id),
                ContextCopy(title: "Copy Folder Path", systemImage: "folder", text: openCode.directory),
            ]
        case .claudeCode, .codex, .cursor: []
        }
    }

    static func copy(_ context: ContextCopy) {
        SessionHost.copy(context.text)
    }

    /// Why a session without a route can't be opened, and what can be done instead.
    static func unavailableHelp(for session: AgentSession) -> String {
        switch session.source {
        case .openCode:
            "Can't be opened from here: Sidelight can't tell which OpenCode would show this session. "
                + "Right-click to copy its session ID or folder."
        case .claudeCode, .codex, .cursor:
            canCopyResumeCommand(of: session)
                ? "Can't be opened from here. Right-click to copy the command that resumes it."
                : "Can't be opened from here"
        }
    }
}

extension String {
    fileprivate var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
