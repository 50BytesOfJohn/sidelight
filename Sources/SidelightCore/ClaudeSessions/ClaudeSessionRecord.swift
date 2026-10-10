import Foundation

/// Where a Claude Code session runs, the way Claude Code's own agent view tells them apart.
public enum ClaudeSessionSurface: String, Hashable, Sendable {
    case terminal
    /// The Code tab of the Claude desktop app.
    case desktop
    case vscode
    /// Started through the Agent SDK or `claude -p`, by a script or another app.
    case sdk
    /// Background jobs and workers, not attached to a terminal or app.
    case background
}

/// One entry of Claude Code's session registry: `~/.claude/sessions/<pid>.json`, which every running Claude Code
/// process (the CLI, the desktop app's sessions, IDE extensions, `claude -p`) keeps up to date for its own agent view
/// and deletes when it exits.
///
/// Undocumented, so it's read leniently: a field that's missing or changes type reads as unknown rather than
/// dropping the session.
public struct ClaudeSessionRecord: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        /// Claude is running a turn.
        case busy
        /// Claude is waiting for the user: a permission prompt, a question, a dialog.
        case waiting
        /// The turn is over, or nothing has run yet.
        case idle
        /// Not written yet, or a value this version doesn't know.
        case unknown
    }

    public var pid: Int32
    public var sessionID: String
    public var cwd: String?
    public var name: String?
    /// The name was chosen by someone (`/rename`, the desktop app's title) rather than derived from the folder.
    public var isNamed: Bool
    public var startedAt: Date
    public var status: Status
    /// What a waiting session waits for: `permission prompt`, `input needed`, `dialog open`, …
    public var waitingFor: String?
    public var statusChangedAt: Date?
    public var surface: ClaudeSessionSurface
    /// The desktop app's own ID for the session (`local_…`), for sessions it hosts.
    public var desktopSessionID: String?
    /// A process started ahead of time to make the next session open faster; nobody uses it yet.
    public var isSpare: Bool

    public init(
        pid: Int32, sessionID: String, cwd: String? = nil, name: String? = nil, isNamed: Bool = false,
        startedAt: Date, status: Status, waitingFor: String? = nil, statusChangedAt: Date? = nil,
        surface: ClaudeSessionSurface = .terminal, desktopSessionID: String? = nil, isSpare: Bool = false
    ) {
        self.pid = pid
        self.sessionID = sessionID
        self.cwd = cwd
        self.name = name
        self.isNamed = isNamed
        self.startedAt = startedAt
        self.status = status
        self.waitingFor = waitingFor
        self.statusChangedAt = statusChangedAt
        self.surface = surface
        self.desktopSessionID = desktopSessionID
        self.isSpare = isSpare
    }

    private struct Payload: Decodable {
        var pid: Int32?
        var sessionID: String?
        var cwd: String?
        var name: String?
        var nameSource: String?
        var startedAt: Int64?
        var status: String?
        var waitingFor: String?
        var statusUpdatedAt: Int64?
        var kind: String?
        var entrypoint: String?
        var hostSessionID: String?
        var spare: Bool?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            pid = container.lenientInt64("pid").flatMap { Int32(exactly: $0) }
            sessionID = container.lenient(String.self, "sessionId")
            cwd = container.lenient(String.self, "cwd")
            name = container.lenient(String.self, "name")
            nameSource = container.lenient(String.self, "nameSource")
            startedAt = container.lenientInt64("startedAt")
            status = container.lenient(String.self, "status")
            waitingFor = container.lenient(String.self, "waitingFor")
            statusUpdatedAt = container.lenientInt64("statusUpdatedAt")
            kind = container.lenient(String.self, "kind")
            entrypoint = container.lenient(String.self, "entrypoint")
            hostSessionID = container.lenient(String.self, "hostSessionId")
            spare = container.lenient(Bool.self, "spare")
        }
    }

    /// `nil` for a file without the process, session or start time, which can't be matched to a live process.
    public init?(json: Data) {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: json),
            let pid = payload.pid, let sessionID = payload.sessionID, !sessionID.isEmpty,
            let startedAt = payload.startedAt
        else { return nil }
        self.init(
            pid: pid,
            sessionID: sessionID,
            cwd: payload.cwd,
            name: payload.name.flatMap { $0.isEmpty ? nil : $0 },
            isNamed: payload.nameSource.map { $0 != "derived" } ?? false,
            startedAt: Self.date(milliseconds: startedAt),
            status: Self.status(payload.status),
            waitingFor: payload.waitingFor,
            statusChangedAt: payload.statusUpdatedAt.map(Self.date(milliseconds:)),
            surface: Self.surface(kind: payload.kind, entrypoint: payload.entrypoint),
            desktopSessionID: payload.hostSessionID.flatMap { $0.isEmpty ? nil : $0 },
            isSpare: payload.spare ?? false
        )
    }

    private static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    private static func status(_ value: String?) -> Status {
        switch value {
        case "busy": .busy
        case "waiting": .waiting
        // `shell`: idle, with a background shell still running.
        case "idle", "shell": .idle
        default: .unknown
        }
    }

    private static func surface(kind: String?, entrypoint: String?) -> ClaudeSessionSurface {
        if let kind, kind != "interactive" { return .background }
        return switch entrypoint {
        case "claude-desktop", "claude-desktop-3p", "local-agent": .desktop
        case "claude-vscode": .vscode
        case let entrypoint? where entrypoint.hasPrefix("sdk"): .sdk
        default: .terminal
        }
    }

    /// The last folder of the working directory: `sidelight`.
    public var project: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = URL(filePath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}
