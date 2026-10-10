import Foundation

/// A Claude Code session as the widget shows it.
public struct ClaudeSession: Identifiable, Hashable, Sendable {
    public enum Activity: Hashable, Sendable {
        /// Waiting for the user, and for what: `permission prompt`, `input needed`, …
        case needsInput(String?)
        case working
        /// A turn ended and the session waits for its next prompt.
        case finished
        /// Open, but nothing has run yet.
        case idle
        /// The process exited.
        case closed

        /// Needs the user or is still going: shown however long ago it started.
        public var isOngoing: Bool {
            switch self {
            case .needsInput, .working: true
            case .finished, .idle, .closed: false
            }
        }

        /// Most urgent first: what needs the user, what's running, what just finished, then the rest.
        var rank: Int {
            switch self {
            case .needsInput: 0
            case .working: 1
            case .finished: 2
            case .idle, .closed: 3
            }
        }
    }

    /// Claude Code's session ID.
    public let id: String
    public var title: String
    public var project: String?
    public var surface: ClaudeSessionSurface
    public var activity: Activity
    /// When the session entered its current activity.
    public var since: Date
    /// The Claude Code process, while it runs.
    public var pid: Int32?
    public var cwd: String?
    /// The desktop app's ID for the session, for sessions it hosts.
    public var desktopSessionID: String?

    public init(
        id: String, title: String, project: String? = nil, surface: ClaudeSessionSurface = .terminal,
        activity: Activity, since: Date, pid: Int32? = nil, cwd: String? = nil, desktopSessionID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.project = project
        self.surface = surface
        self.activity = activity
        self.since = since
        self.pid = pid
        self.cwd = cwd
        self.desktopSessionID = desktopSessionID
    }
}

/// Follows Claude Code's session registry from one read to the next: maps each live record to what it's doing and
/// keeps sessions whose process exited as closed, since the registry forgets them.
public struct ClaudeSessionTracker: Sendable {
    /// Closed sessions are forgotten this long after they closed.
    public static let closedRetention: TimeInterval = 24 * 60 * 60
    /// An idle session whose status last changed this long after it started has run a turn: the status written when
    /// the session opens lands within a second or two.
    static let startupGrace: TimeInterval = 5

    /// Most urgent first, then newest first.
    public private(set) var sessions: [ClaudeSession] = []
    /// Sessions seen working, for those that finish quicker than ``startupGrace`` after opening.
    private var workedSessionIDs: Set<String> = []

    public init() {}

    /// `records` are the sessions running now; `titles` are titles read from transcripts, by session ID.
    public mutating func update(records: [ClaudeSessionRecord], titles: [String: String], now: Date) {
        // A session resumed in a second process shows up twice for a moment; the newest status wins.
        var live: [String: ClaudeSessionRecord] = [:]
        for record in records where !record.isSpare {
            if let other = live[record.sessionID], other.lastChange >= record.lastChange { continue }
            live[record.sessionID] = record
        }
        var next = live.values.map { session(for: $0, transcriptTitle: titles[$0.sessionID]) }
        for previous in sessions where live[previous.id] == nil {
            if previous.activity == .closed {
                if now.timeIntervalSince(previous.since) < Self.closedRetention { next.append(previous) }
            } else {
                var closed = previous
                closed.activity = .closed
                closed.since = now
                closed.pid = nil
                next.append(closed)
                workedSessionIDs.remove(previous.id)
            }
        }
        sessions = next.sorted(by: Self.isOrderedBefore)
    }

    private mutating func session(for record: ClaudeSessionRecord, transcriptTitle: String?) -> ClaudeSession {
        let activity: ClaudeSession.Activity
        switch record.status {
        case .busy:
            workedSessionIDs.insert(record.sessionID)
            activity = .working
        case .waiting:
            activity = .needsInput(record.waitingFor)
        case .idle, .unknown:
            let hasWorked =
                workedSessionIDs.contains(record.sessionID)
                || record.lastChange.timeIntervalSince(record.startedAt) > Self.startupGrace
            activity = hasWorked ? .finished : .idle
        }
        return ClaudeSession(
            id: record.sessionID,
            title: Self.title(of: record, transcriptTitle: transcriptTitle),
            project: record.project,
            surface: record.surface,
            activity: activity,
            since: record.lastChange,
            pid: record.pid,
            cwd: record.cwd,
            desktopSessionID: record.desktopSessionID
        )
    }

    /// A name someone chose, then the transcript's title, then the name Claude Code made up from the folder.
    static func title(of record: ClaudeSessionRecord, transcriptTitle: String?) -> String {
        if record.isNamed, let name = record.name { return name }
        return transcriptTitle ?? record.name ?? record.project ?? "Claude Code"
    }

    static func isOrderedBefore(_ lhs: ClaudeSession, _ rhs: ClaudeSession) -> Bool {
        if lhs.activity.rank != rhs.activity.rank { return lhs.activity.rank < rhs.activity.rank }
        if lhs.since != rhs.since { return lhs.since > rhs.since }
        return lhs.id < rhs.id
    }
}

extension ClaudeSessionRecord {
    /// When the status last changed, or when the session started if it never has.
    public var lastChange: Date { statusChangedAt ?? startedAt }
}

extension [ClaudeSession] {
    /// Ongoing sessions, and the others whose activity started within `window` of `now`.
    public func recent(within window: TimeInterval, now: Date) -> [ClaudeSession] {
        filter { $0.activity.isOngoing || now.timeIntervalSince($0.since) <= window }
    }
}
