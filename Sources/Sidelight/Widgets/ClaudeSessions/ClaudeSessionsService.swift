import Foundation
import Observation
import SidelightCore
import os

/// Running and recently finished Claude Code sessions, from Claude Code's session registry
/// (`~/.claude/sessions/<pid>.json`): every Claude Code process (terminal, desktop app, IDE, `claude -p`) writes its
/// status there as it changes and deletes the file when it exits. No setup and nothing to install.
///
/// The folder is watched with FSEvents, so a session that finishes or starts waiting shows within a fraction of a
/// second, and nothing runs while sessions sit still. The registry is undocumented; if a Claude Code update moves it,
/// the widget says it can't find it rather than showing anything wrong.
@Observable
final class ClaudeSessionsService {
    nonisolated static let registryDirectory = URL.homeDirectory.appending(
        path: ".claude/sessions", directoryHint: .isDirectory)
    /// FSEvents gathers a burst of writes for this long before telling us.
    static let eventLatency: TimeInterval = 0.1
    /// A process that's killed can't delete its file, so while sessions are working or waiting, their processes are
    /// checked this often. Also how often to look for the registry while it doesn't exist.
    static let sweepInterval: Duration = .seconds(30)

    /// Most urgent first, then newest first, including closed sessions from the last day.
    private(set) var sessions: [ClaudeSession] = []
    /// The registry has been read at least once.
    private(set) var hasLoaded = false
    /// The registry folder exists. Claude Code creates it the first time a session runs.
    private(set) var registryExists = true

    @ObservationIgnored private var tracker = ClaudeSessionTracker()
    /// The last record read from each process's file, kept for a moment when the file is caught mid-write.
    @ObservationIgnored private var records: [Int32: ClaudeSessionRecord] = [:]
    @ObservationIgnored private var titles: [String: TranscriptTitle] = [:]
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var watcher: FileEventStream?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var needsReload = false
    @ObservationIgnored private var sweepTask: Task<Void, Never>?

    /// A session's title from its transcript, and the status change it was read after.
    private struct TranscriptTitle {
        var title: String?
        var readAfter: Date
    }

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        watchRegistry()
        scheduleReload()
    }

    func stop() {
        isEnabled = false
        watcher = nil
        reloadTask?.cancel()
        reloadTask = nil
        sweepTask?.cancel()
        sweepTask = nil
    }

    private func watchRegistry() {
        guard watcher == nil else { return }
        watcher = FileEventStream(directory: Self.registryDirectory, latency: Self.eventLatency, queue: .main) {
            [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
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
        let read = await Self.readRegistry(Self.registryDirectory, previous: records)
        guard isEnabled, !Task.isCancelled else { return }
        if read == nil, registryExists {
            Log.claudeSessions.notice("No Claude Code session registry at \(Self.registryPath, privacy: .public)")
        }
        registryExists = read != nil
        records = read ?? [:]
        let live = Array(records.values)

        // Transcript titles change after a turn, so each session's is read again once its status has changed.
        let stale = live.filter { !$0.isNamed && titles[$0.sessionID]?.readAfter != $0.lastChange }
        if !stale.isEmpty {
            let fresh = await Self.readTitles(of: stale.map { ($0.sessionID, $0.cwd) })
            guard isEnabled, !Task.isCancelled else { return }
            for record in stale {
                let title = fresh[record.sessionID] ?? titles[record.sessionID]?.title
                titles[record.sessionID] = TranscriptTitle(title: title, readAfter: record.lastChange)
            }
        }

        tracker.update(records: live, titles: titles.compactMapValues(\.title), now: .now)
        let known = Set(tracker.sessions.map(\.id))
        titles = titles.filter { known.contains($0.key) }
        if tracker.sessions != sessions { sessions = tracker.sessions }
        hasLoaded = true
        updateSweep(needed: read == nil || live.contains { $0.status == .busy || $0.status == .waiting })
    }

    private func updateSweep(needed: Bool) {
        guard needed else {
            sweepTask?.cancel()
            sweepTask = nil
            return
        }
        guard sweepTask == nil else { return }
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.sweepInterval, tolerance: .seconds(10)) } catch { return }
                guard let self, isEnabled else { return }
                if !registryExists, FileManager.default.fileExists(atPath: Self.registryPath) {
                    // FSEvents may not report into a folder created after the stream started.
                    watcher = nil
                    watchRegistry()
                }
                scheduleReload()
            }
        }
    }

    private nonisolated static var registryPath: String { registryDirectory.path(percentEncoded: false) }

    /// The records of sessions whose process is still running, by process ID; `nil` when the folder doesn't exist.
    /// A file that doesn't decode, likely caught mid-write, keeps its process's `previous` record.
    @concurrent
    private static func readRegistry(
        _ directory: URL, previous: [Int32: ClaudeSessionRecord]
    ) async -> [Int32: ClaudeSessionRecord]? {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        else { return nil }
        var records: [Int32: ClaudeSessionRecord] = [:]
        for file in files where file.pathExtension == "json" {
            guard let pid = Int32(file.deletingPathExtension().lastPathComponent) else { continue }
            let record = (try? Data(contentsOf: file)).flatMap(ClaudeSessionRecord.init(json:)) ?? previous[pid]
            guard let record, ProcessTable.isRunning(record.pid, startedBy: record.startedAt) else { continue }
            records[pid] = record
        }
        return records
    }

    @concurrent
    private static func readTitles(of sessions: [(id: String, cwd: String?)]) async -> [String: String] {
        var titles: [String: String] = [:]
        for session in sessions {
            guard let url = ClaudeTranscript.url(sessionID: session.id, cwd: session.cwd) else { continue }
            titles[session.id] = ClaudeTranscript.title(at: url)
        }
        return titles
    }
}
