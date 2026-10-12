import Foundation
import Observation
import SidelightCore
import os

/// Recent OpenCode 2 sessions, from the session list in OpenCode's own database (see ``OpenCodeSessionIndex``). No
/// setup, no sign-in, no server and nothing sent anywhere: titles, folders and times only.
///
/// OpenCode keeps no live status there, so sessions are listed by when they last changed, never as working or
/// waiting. The database's folder is watched with FSEvents; OpenCode writes to it often while it works, so changes
/// are gathered for a while before one small read, and nothing runs while OpenCode is quiet.
@Observable
final class OpenCodeSessionsService {
    /// Where OpenCode's CLI would keep its sessions, given the environment Sidelight was started with.
    nonisolated static let location = OpenCodeSessionIndex.location(
        environment: ProcessInfo.processInfo.environment, home: .homeDirectory)
    /// The database read, when it's a file.
    nonisolated static var database: URL? {
        if case .file(let url) = location { url } else { nil }
    }
    /// Sessions are listed for up to this long after they last changed; each widget shows less.
    nonisolated static let lookback: TimeInterval = 24 * 60 * 60
    /// FSEvents gathers a burst of writes for this long before telling us. A list without live status doesn't need
    /// to be any fresher.
    static let eventLatency: TimeInterval = 10
    /// How often to look for OpenCode while it isn't found, or read its sessions while its folder can't be watched.
    static let missingSweepInterval: Duration = .seconds(120)

    enum Availability: Equatable {
        case found
        /// No database: OpenCode 2 isn't installed or hasn't run, or keeps it somewhere not looked at.
        case notFound
        /// OpenCode 1's format, a database this version can't read, or one kept in memory.
        case unsupported
        /// The last read failed; the sessions read before it, if any, stay.
        case unreadable
    }

    /// Newest first, from the last day.
    private(set) var sessions: [OpenCodeSession] = []
    /// The session list has been read at least once.
    private(set) var hasLoaded = false
    private(set) var availability = Availability.found

    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var watcher: FileEventStream?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// Tells a reload task that a `stop()` or a newer task replaced it.
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private var needsReload = false
    @ObservationIgnored private var sweepTask: Task<Void, Never>?

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        guard Self.database != nil else {
            // Kept in OpenCode's memory, or nowhere a file can be: nothing to read or watch.
            Log.openCode.notice("OPENCODE_DB names no database file Sidelight can read")
            hasLoaded = true
            availability = .unsupported
            return
        }
        watchStorage()
        scheduleReload()
    }

    func stop() {
        isEnabled = false
        watcher = nil
        reloadGeneration += 1
        reloadTask?.cancel()
        reloadTask = nil
        sweepTask?.cancel()
        sweepTask = nil
    }

    private func watchStorage() {
        guard watcher == nil, let directory = Self.database?.deletingLastPathComponent(),
            FileManager.default.fileExists(atPath: directory.path(percentEncoded: false))
        else { return }
        watcher = FileEventStream(directory: directory, latency: Self.eventLatency, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
    }

    /// Coalesces events that arrive during a read into one more read.
    private func scheduleReload() {
        needsReload = true
        guard reloadTask == nil else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        reloadTask = Task { [weak self] in
            while let self, needsReload, !Task.isCancelled, generation == reloadGeneration {
                needsReload = false
                await reload(generation: generation)
            }
            // A task replaced while it read mustn't drop its replacement's handle.
            if let self, generation == reloadGeneration { reloadTask = nil }
        }
    }

    private func reload(generation: Int) async {
        guard let database = Self.database else { return }
        let result = await Self.read(database, now: .now)
        guard isEnabled, !Task.isCancelled, generation == reloadGeneration else { return }
        hasLoaded = true
        switch result {
        case .success(let read):
            availability = .found
            if read != sessions { sessions = read }
        case .failure(.unreadable):
            // Often mid-write, so the sessions read last stay, and the next change reads it again. Until then it
            // says so rather than passing an unread list for an empty one.
            Log.openCode.info("Couldn't read OpenCode's session list this time")
            availability = .unreadable
        case .failure(.noDatabase):
            // The path names the person's account, and maybe their projects: never logged.
            if availability != .notFound { Log.openCode.notice("No OpenCode database found") }
            availability = .notFound
            if !sessions.isEmpty { sessions = [] }
        case .failure(.unsupported):
            if availability != .unsupported { Log.openCode.notice("OpenCode's database has no OpenCode 2 sessions") }
            availability = .unsupported
            if !sessions.isEmpty { sessions = [] }
        }
        updateSweep(needed: availability == .notFound || watcher == nil)
    }

    /// While OpenCode isn't found, its folder is looked for now and then: FSEvents can't watch a folder that doesn't
    /// exist yet. The same sweep stands in for a stream that couldn't be started, trying it again each time.
    private func updateSweep(needed: Bool) {
        guard needed else {
            sweepTask?.cancel()
            sweepTask = nil
            return
        }
        guard sweepTask == nil else { return }
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.missingSweepInterval, tolerance: .seconds(30))
                } catch { return }
                guard let self, isEnabled else { return }
                watchStorage()
                scheduleReload()
            }
        }
    }

    @concurrent
    private static func read(
        _ database: URL, now: Date
    ) async -> Result<[OpenCodeSession], OpenCodeSessionIndex.Failure> {
        OpenCodeSessionIndex.sessions(updatedSince: now.addingTimeInterval(-lookback), in: database)
    }
}
