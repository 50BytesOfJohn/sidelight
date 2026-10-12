import Foundation
import Observation
import SidelightCore
import os

/// Running and recent Codex sessions, in the terminal, the desktop app, IDEs and other apps built on Codex, from
/// what Codex keeps in `~/.codex`. No setup and nothing to install:
///
/// - The state database indexes every thread with its name, folder, branch and model.
/// - A thread is open while a Codex process holds its `thread-writer-locks/<id>.lock`.
/// - Its rollout file logs each turn's start and end, tool calls, the plan and the context used.
/// - A command that asked to run outside the sandbox waits for approval until its shell starts.
///
/// The sessions and lock folders are watched with FSEvents, and each rollout file is read only where it grew, so a
/// turn that ends shows within a fraction of a second. Opening a session leaves no trace in files, so a slow sweep
/// looks for that. None of this is documented; if Codex moves it, the widget says it can't find Codex rather than
/// showing anything wrong.
@Observable
final class CodexSessionsService: DataService {
    nonisolated static let codexDirectory = CodexThreadIndex.defaultCodexDirectory
    nonisolated static let sessionsDirectory = codexDirectory.appending(path: "sessions", directoryHint: .isDirectory)
    nonisolated static let locksDirectory = CodexThreadLocks.defaultDirectory
    /// Sessions are listed for up to this long after they last changed (open ones however long ago); each widget
    /// shows less.
    nonisolated static let lookback: TimeInterval = 24 * 60 * 60
    /// Subagents are only followed while they're this fresh: the agents working for a session, and the approval
    /// reviewer.
    nonisolated static let subagentLookback: TimeInterval = 60 * 60
    /// FSEvents gathers a burst of writes for this long before telling us. Codex writes many events a second
    /// while it works.
    static let eventLatency: TimeInterval = 0.3
    /// Statuses are in the rollout files; the thread index (names, new threads) is asked at most this often while
    /// Codex writes, and once more after the writes stop.
    nonisolated static let indexInterval: TimeInterval = 5
    /// An approval leaves no trace in Codex's files until the command finishes, so while one is pending, its
    /// shell is looked for this often.
    static let approvalSweepInterval: Duration = .seconds(4)
    /// A Codex process that's killed writes nothing, so while sessions work, their processes are checked this often.
    /// Also how often to look for Codex while it isn't found.
    static let sweepInterval: Duration = .seconds(30)
    /// Opening or closing a session without a turn writes nothing either; noticed at least this often.
    static let idleSweepInterval: Duration = .seconds(120)

    /// Most urgent first, then newest first, from the last day.
    private(set) var sessions: [CodexSession] = []
    /// The plan's limits as the newest rollout reported them, and when.
    private(set) var rateLimits: CodexRateLimits?
    private(set) var rateLimitsCapturedAt: Date?
    /// Codex's files have been read at least once.
    private(set) var hasLoaded = false
    /// Codex's state database and sessions folder exist.
    private(set) var codexFound = true

    @ObservationIgnored private var state = ReadState()
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var watchers: [FileEventStream] = []
    /// The folders being watched. FSEvents may not report into a folder created after its stream started, so the
    /// streams are made again once a missing one appears, or one that couldn't be started can be.
    @ObservationIgnored private var watchedFolders: Set<URL> = []
    @ObservationIgnored private let reload = CoalescedReload()
    @ObservationIgnored private let indexRefresh = DelayedTask()
    @ObservationIgnored private let sweep = RepeatingTask()

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        watchFolders()
        scheduleReload()
    }

    func stop() {
        isEnabled = false
        watchers = []
        watchedFolders = []
        reload.cancel()
        indexRefresh.cancel()
        sweep.stop()
    }

    private func watchFolders() {
        let folders = [Self.sessionsDirectory, Self.locksDirectory]
        let existing = Set(folders.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) })
        guard !existing.isSubset(of: watchedFolders) else { return }
        var watched: Set<URL> = []
        watchers = existing.compactMap { folder in
            let stream = FileEventStream(directory: folder, latency: Self.eventLatency) { [weak self] in
                self?.scheduleReload()
            }
            if stream != nil { watched.insert(folder) }
            return stream
        }
        watchedFolders = watched
    }

    private func scheduleReload() {
        guard isEnabled else { return }
        reload.request { [weak self] in await self?.reloadNow() }
    }

    private func reloadNow() async {
        let read = await Self.read(state, now: .now)
        guard !Task.isCancelled else { return }
        if read == nil, codexFound {
            Log.codexSessions.notice("No Codex state database or sessions folder in ~/.codex")
        }
        codexFound = read != nil
        hasLoaded = true
        watchFolders()
        guard let read else {
            state = ReadState()
            if !sessions.isEmpty { sessions = [] }
            scheduleSweep(every: Self.sweepInterval)
            return
        }
        state = read.state
        if read.sessions != sessions { sessions = read.sessions }
        if read.rateLimits?.0 != rateLimits || read.rateLimits?.1 != rateLimitsCapturedAt {
            rateLimits = read.rateLimits?.0
            rateLimitsCapturedAt = read.rateLimits?.1
        }
        if read.reusedIndex { scheduleIndexRefresh(after: read.state.index?.readAt) }
        scheduleSweep(every: sweepInterval(for: read.sessions))
    }

    /// One more read once the thread index read at `readAt` is due again, so names and new threads that came while
    /// it was reused show even if Codex then goes quiet.
    private func scheduleIndexRefresh(after readAt: Date?) {
        guard !indexRefresh.isPending, let readAt else { return }
        let delay = max(0, readAt.addingTimeInterval(Self.indexInterval).timeIntervalSinceNow)
        indexRefresh.schedule(after: .seconds(delay), tolerance: .seconds(1)) { [weak self] in
            self?.scheduleReload()
        }
    }

    private func sweepInterval(for sessions: [CodexSession]) -> Duration {
        if sessions.contains(where: { if case .needsApproval = $0.activity { true } else { false } }) {
            return Self.approvalSweepInterval
        }
        if sessions.contains(where: \.activity.isOngoing) { return Self.sweepInterval }
        return Self.idleSweepInterval
    }

    private func scheduleSweep(every interval: Duration) {
        sweep.schedule(every: interval) { [weak self] in self?.scheduleReload() }
    }

    /// What one read hands the next: the rollout files as far as they were read, the thread index, and the
    /// processes, for when the process table can't be read.
    private struct ReadState: Sendable {
        var followers: [String: CodexRolloutFollower] = [:]
        var index: ThreadIndex?
        var processes: [ProcessEntry] = []
        var holders: [String: Int32] = [:]
    }

    /// The thread index as last read, and when.
    private struct ThreadIndex: Sendable {
        var threads: [CodexThreadRow]
        var readAt: Date
    }

    private struct Read: Sendable {
        var sessions: [CodexSession]
        var state: ReadState
        var rateLimits: (CodexRateLimits, Date)?
        /// The thread index wasn't due, so the last one was used.
        var reusedIndex: Bool
    }

    /// Everything read again: rollout files only where they grew, the thread index once `indexInterval` has
    /// passed or a thread it doesn't list is open. `nil` when Codex isn't found.
    @concurrent
    private static func read(_ previous: ReadState, now: Date) async -> Read? {
        var state = previous
        if let processes = ProcessTable.snapshot() {
            state.processes = processes
            state.holders = CodexThreadLocks.holders(in: locksDirectory, processes: processes)
        }

        let listed = Set(state.index?.threads.map(\.id) ?? [])
        let isDue = state.index.map { now.timeIntervalSince($0.readAt) >= indexInterval } ?? true
        var reusedIndex = !isDue && state.holders.keys.allSatisfy(listed.contains)
        if !reusedIndex {
            guard FileManager.default.fileExists(atPath: sessionsDirectory.path(percentEncoded: false)),
                let database = CodexThreadIndex.databaseURL(in: codexDirectory)
            else { return nil }
            if let threads = CodexThreadIndex.threads(
                updatedSince: now.addingTimeInterval(-lookback), including: Set(state.holders.keys), in: database)
            {
                state.index = ThreadIndex(threads: threads, readAt: now)
            } else if var index = state.index {
                // Most likely mid-write: the threads read last stay, rather than reading as no Codex at all, and
                // the index is tried again once it's due.
                index.readAt = now
                state.index = index
                reusedIndex = true
            } else {
                return nil
            }
        }
        guard let threads = state.index?.threads else { return nil }

        var followers: [String: CodexRolloutFollower] = [:]
        for thread in threads
        where !thread.isSubagent || now.timeIntervalSince(thread.updatedAt) < subagentLookback
            || state.holders[thread.id] != nil
        {
            var follower = previous.followers[thread.id] ?? CodexRolloutFollower()
            follower.read(URL(filePath: thread.rolloutPath))
            followers[thread.id] = follower
        }
        state.followers = followers
        let logs = followers.mapValues(\.state)
        return Read(
            sessions: CodexSessionTracker.sessions(
                threads: threads, holders: state.holders, logs: logs, processes: state.processes),
            state: state,
            rateLimits: CodexSessionTracker.latestRateLimits(in: logs.values),
            reusedIndex: reusedIndex
        )
    }
}
