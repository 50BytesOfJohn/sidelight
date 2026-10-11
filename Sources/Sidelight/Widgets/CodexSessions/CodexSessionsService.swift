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
/// turn that ends shows within a fraction of a second and nothing runs while sessions sit still. None of this is
/// documented; if Codex moves it, the widget says it can't find Codex rather than showing anything wrong.
@Observable
final class CodexSessionsService {
    nonisolated static let codexDirectory = CodexThreadIndex.defaultCodexDirectory
    nonisolated static let sessionsDirectory = codexDirectory.appending(path: "sessions", directoryHint: .isDirectory)
    nonisolated static let locksDirectory = CodexThreadLocks.defaultDirectory
    /// Sessions are listed for up to this long after they last changed; each widget shows less.
    nonisolated static let lookback: TimeInterval = 24 * 60 * 60
    /// Subagents are only followed while they're this fresh: the agents working for a session, and the approval
    /// reviewer.
    nonisolated static let subagentLookback: TimeInterval = 60 * 60
    /// FSEvents gathers a burst of writes for this long before telling us. Codex writes many events a second
    /// while it works.
    static let eventLatency: TimeInterval = 0.3
    /// Statuses are in the rollout files; the thread index (names, new threads) is asked at most this often while
    /// Codex writes.
    nonisolated static let indexInterval: TimeInterval = 5
    /// An approval leaves no trace in Codex's files until the command finishes, so while one is pending, its
    /// shell is looked for this often.
    static let approvalSweepInterval: Duration = .seconds(4)
    /// A Codex process that's killed writes nothing, so while sessions work, their processes are checked this often.
    /// Also how often to look for Codex while it isn't found.
    static let sweepInterval: Duration = .seconds(30)
    /// Closing an idle session writes nothing either; noticed at least this often while any session is open.
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

    @ObservationIgnored private var followers: [String: CodexRolloutFollower] = [:]
    @ObservationIgnored private var index: ThreadIndex?
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var watchers: [FileEventStream] = []
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var needsReload = false
    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    @ObservationIgnored private var sweepInterval: Duration?

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        watchFolders()
        scheduleReload()
    }

    func stop() {
        isEnabled = false
        watchers = []
        reloadTask?.cancel()
        reloadTask = nil
        updateSweep(interval: nil)
    }

    private func watchFolders() {
        guard watchers.isEmpty else { return }
        watchers = [Self.sessionsDirectory, Self.locksDirectory].compactMap { folder in
            FileEventStream(directory: folder, latency: Self.eventLatency, queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.scheduleReload() }
            }
        }
    }

    /// Coalesces events that arrive during a read into one more read.
    private func scheduleReload() {
        needsReload = true
        guard reloadTask == nil else { return }
        reloadTask = Task { [weak self] in
            while let self, needsReload, !Task.isCancelled {
                needsReload = false
                await reload()
            }
            self?.reloadTask = nil
        }
    }

    private func reload() async {
        let read = await Self.read(followers: followers, index: index, now: .now)
        guard isEnabled, !Task.isCancelled else { return }
        if read == nil, codexFound {
            Log.codexSessions.notice("No Codex state database or sessions folder in ~/.codex")
        }
        codexFound = read != nil
        hasLoaded = true
        guard let read else {
            followers = [:]
            index = nil
            if !sessions.isEmpty { sessions = [] }
            updateSweep(interval: Self.sweepInterval)
            return
        }
        followers = read.followers
        index = read.index
        if read.sessions != sessions { sessions = read.sessions }
        if read.rateLimits?.0 != rateLimits || read.rateLimits?.1 != rateLimitsCapturedAt {
            rateLimits = read.rateLimits?.0
            rateLimitsCapturedAt = read.rateLimits?.1
        }
        updateSweep(interval: sweepInterval(for: read.sessions))
    }

    private func sweepInterval(for sessions: [CodexSession]) -> Duration? {
        if sessions.contains(where: { if case .needsApproval = $0.activity { true } else { false } }) {
            return Self.approvalSweepInterval
        }
        if sessions.contains(where: \.activity.isOngoing) { return Self.sweepInterval }
        if sessions.contains(where: { $0.pid != nil }) { return Self.idleSweepInterval }
        return nil
    }

    private func updateSweep(interval: Duration?) {
        guard interval != sweepInterval || (interval != nil && sweepTask == nil) else { return }
        sweepTask?.cancel()
        sweepTask = nil
        sweepInterval = interval
        guard let interval else { return }
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval, tolerance: interval / 4) } catch { return }
                guard let self, isEnabled else { return }
                if watchers.count < 2 {
                    // FSEvents may not report into a folder created after the stream started.
                    watchers = []
                    watchFolders()
                }
                scheduleReload()
            }
        }
    }

    /// The thread index as last read, and when.
    private struct ThreadIndex: Sendable {
        var threads: [CodexThreadRow]
        var readAt: Date
    }

    private struct Read: Sendable {
        var sessions: [CodexSession]
        var followers: [String: CodexRolloutFollower]
        var index: ThreadIndex
        var rateLimits: (CodexRateLimits, Date)?
    }

    /// Everything read again: rollout files only where they grew, the thread index once `indexInterval` has
    /// passed. `nil` when Codex isn't found.
    @concurrent
    private static func read(
        followers previous: [String: CodexRolloutFollower], index: ThreadIndex?, now: Date
    ) async -> Read? {
        var index = index
        if index.map({ now.timeIntervalSince($0.readAt) >= indexInterval }) ?? true {
            guard FileManager.default.fileExists(atPath: sessionsDirectory.path(percentEncoded: false)),
                let database = CodexThreadIndex.databaseURL(in: codexDirectory),
                let threads = CodexThreadIndex.threads(updatedSince: now.addingTimeInterval(-lookback), in: database)
            else { return nil }
            index = ThreadIndex(threads: threads, readAt: now)
        }
        guard let index else { return nil }
        let threads = index.threads
        let processes = ProcessTable.snapshot()
        let holders = CodexThreadLocks.holders(in: locksDirectory, processes: processes)

        var followers: [String: CodexRolloutFollower] = [:]
        for thread in threads
        where !thread.isSubagent || now.timeIntervalSince(thread.updatedAt) < subagentLookback
            || holders[thread.id] != nil
        {
            var follower = previous[thread.id] ?? CodexRolloutFollower()
            follower.read(URL(filePath: thread.rolloutPath))
            followers[thread.id] = follower
        }
        let logs = followers.mapValues(\.state)
        return Read(
            sessions: CodexSessionTracker.sessions(
                threads: threads, holders: holders, logs: logs, processes: processes),
            followers: followers,
            index: index,
            rateLimits: CodexSessionTracker.latestRateLimits(in: logs.values)
        )
    }
}
