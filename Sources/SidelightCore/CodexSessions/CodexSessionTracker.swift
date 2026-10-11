import Foundation

/// Where a Codex session runs.
public enum CodexSessionSurface: Hashable, Sendable {
    /// The `codex` CLI in a terminal.
    case terminal
    /// The Codex desktop app.
    case desktop
    /// The Codex extension in VS Code or another editor.
    case ide
    /// `codex exec`, run by a script or CI.
    case exec
    /// Another app built on Codex, by the name it gives itself.
    case other(String)

    /// From the client that started the session, or else its source.
    init(originator: String?, source: String) {
        switch originator {
        case "codex-tui", "codex_cli_rs": self = .terminal
        case "codex_vscode": self = .ide
        case "codex_exec": self = .exec
        case let name? where name.localizedCaseInsensitiveContains("desktop"): self = .desktop
        case let name? where !name.isEmpty: self = .other(name)
        default:
            self =
                switch source {
                case "exec": .exec
                // Older desktop apps recorded their sessions as VS Code's.
                case "vscode", "appServer": .desktop
                default: .terminal
                }
        }
    }
}

/// A Codex session as the widget shows it.
public struct CodexSession: Identifiable, Hashable, Sendable {
    public enum Activity: Hashable, Sendable {
        /// A command waits for approval to run outside the sandbox, with Codex's reason for it.
        case needsApproval(String?)
        /// Codex asked the user a question.
        case needsInput
        /// A turn is running; `reviewing` while Codex's own reviewer decides on an approval.
        case working(reviewing: Bool)
        /// A turn ended and the session waits for its next prompt.
        case finished
        /// The last turn was interrupted.
        case stopped
        /// Open, but nothing has run yet.
        case idle
        /// No Codex process has it open.
        case closed

        /// Needs the user or is still going: shown however long ago it started.
        public var isOngoing: Bool {
            switch self {
            case .needsApproval, .needsInput, .working: true
            case .finished, .stopped, .idle, .closed: false
            }
        }

        public var needsUser: Bool {
            switch self {
            case .needsApproval, .needsInput: true
            default: false
            }
        }

        /// Most urgent first: what needs the user, what's running, what just finished, then the rest.
        var rank: Int {
            switch self {
            case .needsApproval, .needsInput: 0
            case .working: 1
            case .finished: 2
            case .stopped, .idle, .closed: 3
            }
        }
    }

    /// Codex's thread ID.
    public let id: String
    public var title: String
    public var project: String?
    public var branch: String?
    public var cwd: String?
    public var surface: CodexSessionSurface
    public var activity: Activity
    /// When the session entered its current activity.
    public var since: Date
    /// The Codex process that has it open, while one does.
    public var pid: Int32?
    public var model: String?
    public var reasoningEffort: String?
    public var context: CodexContextUsage?
    /// The plan's steps, when the current or last turn made or updated one.
    public var plan: [CodexPlanStep]
    /// Files the current or last turn changed.
    public var changedFileCount: Int
    /// The agent's latest message, on one line.
    public var lastMessage: String?
    public var lastTurnDuration: TimeInterval?
    /// Nicknames of the agents it spawned that are working now.
    public var workingSubagents: [String]

    public init(
        id: String, title: String, project: String? = nil, branch: String? = nil, cwd: String? = nil,
        surface: CodexSessionSurface = .terminal, activity: Activity, since: Date, pid: Int32? = nil,
        model: String? = nil, reasoningEffort: String? = nil, context: CodexContextUsage? = nil,
        plan: [CodexPlanStep] = [], changedFileCount: Int = 0, lastMessage: String? = nil,
        lastTurnDuration: TimeInterval? = nil, workingSubagents: [String] = []
    ) {
        self.id = id
        self.title = title
        self.project = project
        self.branch = branch
        self.cwd = cwd
        self.surface = surface
        self.activity = activity
        self.since = since
        self.pid = pid
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.context = context
        self.plan = plan
        self.changedFileCount = changedFileCount
        self.lastMessage = lastMessage
        self.lastTurnDuration = lastTurnDuration
        self.workingSubagents = workingSubagents
    }

    public var isExec: Bool { surface == .exec }
}

/// Puts Codex's thread index, its lock holders, the rollout files and the process table together into sessions.
public enum CodexSessionTracker {
    /// Shells Codex runs commands in. One started under the session's Codex process after a command asked for
    /// approval means it was approved and is running.
    static let shellNames: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "pwsh"]
    /// Allowed between a call being logged and the process it starts, or the review it triggers.
    static let causalSlack: TimeInterval = 2

    /// `threads` are what the index lists, subagents included; `holders` the process with each thread open;
    /// `logs` what each rollout file says, by thread ID. Most urgent first, then newest first. Subagents aren't
    /// listed: they show on the session that started them.
    public static func sessions(
        threads: [CodexThreadRow], holders: [String: Int32], logs: [String: CodexRolloutState],
        processes: [ProcessEntry]
    ) -> [CodexSession] {
        let subagents = threads.filter(\.isSubagent)
        return threads.filter { !$0.isSubagent }.map { thread in
            session(
                for: thread, pid: holders[thread.id], log: logs[thread.id] ?? CodexRolloutState(),
                reviewers: subagents.compactMap { reviewer in
                    guard let log = logs[reviewer.id], log.meta?.isApprovalReviewer == true,
                        log.meta?.parentThreadID == thread.id
                    else { return nil }
                    return log
                },
                subagents: subagents.filter { $0.parentThreadID == thread.id }.filter {
                    holders[$0.id] != nil && logs[$0.id]?.turn.isRunning == true
                },
                processes: processes
            )
        }
        .sorted(by: isOrderedBefore)
    }

    static func session(
        for thread: CodexThreadRow, pid: Int32?, log: CodexRolloutState, reviewers: [CodexRolloutState],
        subagents: [CodexThreadRow], processes: [ProcessEntry]
    ) -> CodexSession {
        let (activity, since) = activity(of: thread, pid: pid, log: log, reviewers: reviewers, processes: processes)
        return CodexSession(
            id: thread.id,
            title: title(of: thread),
            project: thread.cwd.flatMap(project(of:)),
            branch: thread.gitBranch,
            cwd: thread.cwd,
            surface: CodexSessionSurface(originator: thread.originator ?? log.meta?.originator, source: thread.source),
            activity: activity,
            since: since,
            pid: pid,
            model: thread.model,
            reasoningEffort: thread.reasoningEffort,
            context: log.context,
            plan: log.planIsCurrent ? log.plan : [],
            changedFileCount: log.changedFiles.count,
            lastMessage: log.lastMessage,
            lastTurnDuration: log.lastTurnDuration,
            workingSubagents: subagents.map { $0.agentNickname ?? $0.name ?? "Agent" }
        )
    }

    private static func activity(
        of thread: CodexThreadRow, pid: Int32?, log: CodexRolloutState, reviewers: [CodexRolloutState],
        processes: [ProcessEntry]
    ) -> (CodexSession.Activity, Date) {
        guard let pid else { return (.closed, thread.updatedAt) }
        switch log.turn {
        case .running(let since):
            guard let pending = log.firstPendingCall else { return (.working(reviewing: false), since) }
            let calledAt = pending.calledAt.addingTimeInterval(-causalSlack)
            switch pending.kind {
            case .question:
                return (.needsInput, pending.calledAt)
            case .escalation(let justification):
                if reviewers.contains(where: { $0.turn.map { $0.changed(after: calledAt) } ?? false }) {
                    return (.working(reviewing: true), since)
                }
                let started = processes.descendants(of: pid).contains {
                    shellNames.contains($0.name) && $0.startedAt >= calledAt
                }
                return started ? (.working(reviewing: false), since) : (.needsApproval(justification), pending.calledAt)
            }
        case .completed(let at): return (.finished, at)
        case .aborted(let at): return (.stopped, at)
        case nil: return (.idle, thread.createdAt > .distantPast ? thread.createdAt : thread.updatedAt)
        }
    }

    /// The name Codex gave it, or else the start of the first prompt. The desktop app wraps prompts with files
    /// attached in a heading; the request itself comes after `## My request:`.
    static func title(of thread: CodexThreadRow) -> String {
        if let name = thread.name.flatMap(CodexRolloutReducer.oneLine) { return name }
        if var title = thread.title {
            if let request = title.range(of: "## My request:") { title = String(title[request.upperBound...]) }
            if let line = CodexRolloutReducer.oneLine(title) { return String(line.prefix(120)) }
        }
        return thread.cwd.flatMap(project(of:)) ?? "Codex"
    }

    /// The last folder of the working directory: `sidelight`.
    static func project(of cwd: String) -> String? {
        let name = URL(filePath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    static func isOrderedBefore(_ lhs: CodexSession, _ rhs: CodexSession) -> Bool {
        if lhs.activity.rank != rhs.activity.rank { return lhs.activity.rank < rhs.activity.rank }
        if lhs.since != rhs.since { return lhs.since > rhs.since }
        return lhs.id < rhs.id
    }

    /// The newest rate limits any of `logs` reported, and when.
    public static func latestRateLimits(in logs: some Sequence<CodexRolloutState>) -> (CodexRateLimits, Date)? {
        logs.compactMap { log in log.rateLimits.flatMap { limits in log.rateLimitsCapturedAt.map { (limits, $0) } } }
            .max { $0.1 < $1.1 }
    }
}

extension CodexRolloutState.Turn {
    /// Whether the turn started, or ended, after `date`.
    func changed(after date: Date) -> Bool {
        switch self {
        case .running(let since): since >= date
        case .completed(let at), .aborted(let at): at >= date
        }
    }
}

extension CodexRolloutState.Turn? {
    var isRunning: Bool {
        if case .running = self { true } else { false }
    }
}

extension [CodexSession] {
    /// Ongoing sessions, and the others whose activity started within `window` of `now`.
    public func recent(within window: TimeInterval, now: Date) -> [CodexSession] {
        filter { $0.activity.isOngoing || now.timeIntervalSince($0.since) <= window }
    }
}

/// Ways back into a Codex session from outside it.
public enum CodexSessionLinks {
    /// Opens the thread in the Codex desktop app, whichever client started it.
    public static func appURL(threadID: String) -> URL? {
        guard threadID.wholeMatch(of: /[A-Za-z0-9-]{1,64}/) != nil else { return nil }
        return URL(string: "codex://threads/\(threadID)")
    }

    /// A shell command that picks the session up again in its folder: `cd '/code/app' && codex resume <id>`.
    public static func resumeCommand(threadID: String, cwd: String?) -> String {
        let resume = "codex resume \(ClaudeSessionLinks.shellQuoted(threadID))"
        guard let cwd, !cwd.isEmpty else { return resume }
        return "cd \(ClaudeSessionLinks.shellQuoted(cwd)) && \(resume)"
    }
}
