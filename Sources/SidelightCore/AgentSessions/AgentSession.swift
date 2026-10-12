import Foundation

/// A coding agent whose sessions the Agent sessions widget lists. The raw value is stored in `config.json`.
///
/// Adding one: a case here, a reader that turns its sessions into ``AgentSession``s (a new ``AgentSession/Source``
/// case), and in the app its service, logo and a way to open its sessions, or what to offer instead. The compiler
/// flags every switch that needs it. Append new agents: settings saved earlier list the agents they chose, so a new
/// one isn't added to them.
public enum AgentProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claudeCode, cursor, openCode

    public var id: Self { self }
}

/// One session of any agent, the same shape whichever agent it comes from, so one widget can list them together.
/// Each keeps the agent's own session, which says how to open it.
public struct AgentSession: Identifiable, Hashable, Sendable {
    /// The agent and its own durable ID for the session: Claude Code's session ID, Codex's thread ID, Cursor's
    /// chat (composer) ID, OpenCode's `ses_…` ID. Never a process ID, which the next session may reuse.
    public struct ID: Hashable, Sendable {
        public var provider: AgentProvider
        public var sessionID: String

        public init(provider: AgentProvider, sessionID: String) {
            self.provider = provider
            self.sessionID = sessionID
        }
    }

    /// What a session is doing, as far as its agent tells.
    public enum Status: Hashable, Sendable {
        /// A command waits for the user's approval, with the agent's reason for it.
        case needsApproval(String?)
        /// The agent asked the user something, or shows a prompt: what it waits for, when it says.
        case needsInput(String?)
        /// A turn is running; the detail says more, such as Codex's own reviewer deciding on an approval.
        case working(String?)
        /// A turn ended and the session waits for its next prompt.
        case finished
        /// The last turn was interrupted.
        case interrupted
        /// Open, but nothing has run yet.
        case idle
        /// No process has it open any more.
        case closed
        /// The agent wrote a status this version of Sidelight doesn't know.
        case unknown
        /// The agent keeps no live status for it, only when it last changed (Cursor's chats, OpenCode's sessions).
        case untracked

        /// Needs the user or is still going: shown however long ago it started.
        public var isOngoing: Bool {
            switch self {
            case .needsApproval, .needsInput, .working: true
            case .finished, .interrupted, .idle, .closed, .unknown, .untracked: false
            }
        }

        public var needsUser: Bool {
            switch self {
            case .needsApproval, .needsInput: true
            default: false
            }
        }

        public var isWorking: Bool {
            if case .working = self { true } else { false }
        }

        /// Most urgent first: what needs the user, what's running, what just finished, then the rest.
        var rank: Int {
            switch self {
            case .needsApproval, .needsInput: 0
            case .working: 1
            case .finished: 2
            case .interrupted, .idle, .closed, .unknown, .untracked: 3
            }
        }
    }

    /// Where a session runs.
    public enum Surface: Hashable, Sendable {
        case terminal
        /// The agent's own desktop app: the Claude app's Code tab, the Codex app.
        case desktopApp
        /// An editor: VS Code or a fork running the agent's extension, or Cursor itself.
        case editor
        /// Started by a script, CI or another program: the Agent SDK, `claude -p`, `codex exec`, background jobs.
        case background
        /// Another app built on the agent, by the name it gives itself.
        case other(String)
    }

    /// The agent's own session, as its reader made it.
    public enum Source: Hashable, Sendable {
        case claudeCode(ClaudeSession)
        case codex(CodexSession)
        case cursor(CursorChat)
        case openCode(OpenCodeSession)
    }

    public let source: Source
    public var title: String
    /// The last folder of the working directory: `sidelight`.
    public var project: String?
    public var branch: String?
    public var surface: Surface
    public var status: Status
    /// When the session entered its current status; for ``Status/untracked``, when it last changed.
    public var since: Date

    public var id: ID {
        switch source {
        case .claudeCode(let session): ID(provider: .claudeCode, sessionID: session.id)
        case .codex(let session): ID(provider: .codex, sessionID: session.id)
        case .cursor(let chat): ID(provider: .cursor, sessionID: chat.id)
        case .openCode(let session): ID(provider: .openCode, sessionID: session.id)
        }
    }

    public var provider: AgentProvider { id.provider }

    public init(_ session: ClaudeSession) {
        source = .claudeCode(session)
        title = session.title
        project = session.project
        branch = nil
        since = session.since
        surface =
            switch session.surface {
            case .terminal: .terminal
            case .desktop: .desktopApp
            case .vscode: .editor
            case .sdk, .background: .background
            }
        status =
            switch session.activity {
            case .needsInput(let reason): .needsInput(reason)
            case .working: .working(nil)
            case .finished: .finished
            case .idle: .idle
            case .closed: .closed
            case .unknown: .unknown
            }
    }

    public init(_ session: CodexSession) {
        source = .codex(session)
        title = session.title
        project = session.project
        branch = session.branch
        since = session.since
        surface =
            switch session.surface {
            case .terminal: .terminal
            case .desktop: .desktopApp
            case .ide: .editor
            case .exec: .background
            case .other(let name): .other(name)
            }
        status =
            switch session.activity {
            case .needsApproval(let justification): .needsApproval(justification)
            case .needsInput: .needsInput(nil)
            case .working(let reviewing): .working(reviewing ? "auto-review" : nil)
            case .finished: .finished
            case .stopped: .interrupted
            case .idle: .idle
            case .closed: .closed
            }
    }

    public init(_ chat: CursorChat) {
        source = .cursor(chat)
        title = chat.name ?? "Untitled chat"
        project = chat.project
        branch = nil
        surface = .editor
        status = .untracked
        since = chat.updatedAt
    }

    /// OpenCode doesn't say which of its apps a session runs in: its terminal UI, desktop app and background service
    /// share one session list.
    public init(_ session: OpenCodeSession) {
        source = .openCode(session)
        title = session.title ?? "Untitled session"
        project = session.project
        branch = nil
        surface = .other("OpenCode")
        status = .untracked
        since = session.updatedAt
    }

    /// The working directory, where the agent says.
    public var cwd: String? {
        switch source {
        case .claudeCode(let session): session.cwd
        case .codex(let session): session.cwd
        case .cursor(let chat): chat.workspacePath
        case .openCode(let session): session.directory
        }
    }

    /// Whether a running process has it open, as far as Sidelight can tell; `nil` when the agent doesn't say.
    public var isOpen: Bool? {
        switch source {
        case .claudeCode(let session): session.pid != nil
        case .codex(let session): session.pid != nil
        case .cursor, .openCode: nil
        }
    }

    /// Sessions from every agent, most urgent first, then newest first.
    public static func merged(_ groups: some Sequence<[AgentSession]>) -> [AgentSession] {
        groups.joined().sorted(by: isOrderedBefore)
    }

    static func isOrderedBefore(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        if lhs.status.rank != rhs.status.rank { return lhs.status.rank < rhs.status.rank }
        if lhs.since != rhs.since { return lhs.since > rhs.since }
        if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
        return lhs.id.sessionID < rhs.id.sessionID
    }
}

extension [AgentSession] {
    /// Ongoing sessions, and the others whose status started within `window` of `now`.
    public func recent(within window: TimeInterval, now: Date) -> [AgentSession] {
        filter { $0.status.isOngoing || now.timeIntervalSince($0.since) <= window }
    }
}
