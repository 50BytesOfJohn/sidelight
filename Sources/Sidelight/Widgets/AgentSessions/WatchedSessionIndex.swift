import Foundation
import Observation
import SidelightCore
import os

/// Recent sessions from the list another app keeps in its own database, such as Cursor's chats and OpenCode's
/// sessions. No setup, no sign-in and nothing sent anywhere: names, folders and times only.
///
/// These apps keep no live status there, so sessions are listed by when they last changed, never as working or
/// waiting. The database's folder is watched with FSEvents; the apps write to it often while in use, so changes are
/// gathered for ``eventLatency`` before one small read, and nothing runs while the app is quiet.
@Observable
final class WatchedSessionIndex<Session: Equatable & Sendable>: DataService {
    /// Reading a database is file I/O, so it always runs off the main actor.
    typealias Read = @concurrent @Sendable (_ database: URL, _ since: Date) async -> ReadResult
    typealias ReadResult = Result<[Session], SessionIndexFailure>

    enum Availability: Equatable {
        case found
        /// No database: the app isn't installed, or hasn't run.
        case notFound
        /// A version of the app without the list this version reads, or one keeping it where no file can be read.
        case unsupported
        /// The last read failed, such as while the app rewrites the file; the sessions read before it, if any, stay.
        case unreadable
    }

    /// Newest first, from the last ``lookback``.
    private(set) var sessions: [Session] = []
    /// The list has been read at least once.
    private(set) var hasLoaded = false
    private(set) var availability = Availability.found

    /// The app's name, for the log.
    let name: String
    /// The database read; `nil` when the app keeps it somewhere no file can be.
    let database: URL?
    /// Sessions are listed for up to this long after they last changed; each widget shows less.
    let lookback: TimeInterval
    /// FSEvents gathers a burst of writes for this long before telling us. A list without live status doesn't need
    /// to be any fresher.
    let eventLatency: TimeInterval
    /// How often to look for the app while it isn't found, or read its list while its folder can't be watched.
    let missingSweepInterval: Duration

    @ObservationIgnored private let read: Read
    @ObservationIgnored private let log: Logger
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var watcher: FileEventStream?
    @ObservationIgnored private let reload = CoalescedReload()
    @ObservationIgnored private let sweep = RepeatingTask()

    init(
        name: String, database: URL?, log: Logger, lookback: TimeInterval = 24 * 60 * 60,
        eventLatency: TimeInterval = 10, missingSweepInterval: Duration = .seconds(120), read: @escaping Read
    ) {
        self.name = name
        self.database = database
        self.log = log
        self.lookback = lookback
        self.eventLatency = eventLatency
        self.missingSweepInterval = missingSweepInterval
        self.read = read
    }

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        guard database != nil else {
            log.notice("\(self.name, privacy: .public) keeps its sessions where no file can be read")
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
        reload.cancel()
        sweep.stop()
    }

    private func watchStorage() {
        guard watcher == nil, let directory = database?.deletingLastPathComponent(),
            FileManager.default.fileExists(atPath: directory.path(percentEncoded: false))
        else { return }
        watcher = FileEventStream(directory: directory, latency: eventLatency) { [weak self] in
            self?.scheduleReload()
        }
    }

    func scheduleReload() {
        guard isEnabled else { return }
        reload.request { [weak self] in await self?.reloadNow() }
    }

    private func reloadNow() async {
        guard let database else { return }
        let result = await read(database, .now.addingTimeInterval(-lookback))
        guard !Task.isCancelled else { return }
        hasLoaded = true
        switch result {
        case .success(let read):
            availability = .found
            if read != sessions { sessions = read }
        case .failure(.unreadable):
            // Often mid-write, so the sessions read last stay, and the next change reads it again. Until then it says
            // so rather than passing an unread list for an empty one.
            log.info("Couldn't read \(self.name, privacy: .public)'s sessions this time")
            availability = .unreadable
        case .failure(.noDatabase):
            // The path names the person's account, and maybe their projects: never logged.
            if availability != .notFound { log.notice("No \(self.name, privacy: .public) database found") }
            availability = .notFound
            if !sessions.isEmpty { sessions = [] }
        case .failure(.unsupported):
            if availability != .unsupported {
                log.notice("\(self.name, privacy: .public)'s database has no session list this version reads")
            }
            availability = .unsupported
            if !sessions.isEmpty { sessions = [] }
        }
        // While the app isn't found, its folder is looked for now and then: FSEvents can't watch a folder that
        // doesn't exist yet. The same sweep stands in for a stream that couldn't be started, trying it again each time.
        let needsSweep = availability == .notFound || watcher == nil
        sweep.schedule(every: needsSweep ? missingSweepInterval : nil, tolerance: .seconds(30)) { [weak self] in
            self?.watchStorage()
            self?.scheduleReload()
        }
    }
}

typealias CursorChatsService = WatchedSessionIndex<CursorChat>
typealias OpenCodeSessionsService = WatchedSessionIndex<OpenCodeSession>

extension WatchedSessionIndex<CursorChat> {
    /// Recent chats in the Cursor editor and its Agents window, from the chat list Cursor keeps in its global state
    /// database (see ``CursorChatIndex``).
    static func cursor() -> CursorChatsService {
        CursorChatsService(name: "Cursor", database: CursorChatIndex.defaultDatabase, log: Log.cursor) {
            CursorChatIndex.chats(updatedSince: $1, in: $0)
        }
    }
}

extension WatchedSessionIndex<OpenCodeSession> {
    /// Where OpenCode's CLI would keep its sessions, given the environment Sidelight was started with.
    static var location: OpenCodeSessionIndex.Location {
        OpenCodeSessionIndex.location(environment: ProcessInfo.processInfo.environment, home: .homeDirectory)
    }

    /// Recent OpenCode 2 sessions, from the session list in OpenCode's own database (see ``OpenCodeSessionIndex``).
    /// No server is asked.
    static func openCode() -> OpenCodeSessionsService {
        let database: URL? = if case .file(let url) = location { url } else { nil }
        return OpenCodeSessionsService(name: "OpenCode", database: database, log: Log.openCode) {
            OpenCodeSessionIndex.sessions(updatedSince: $1, in: $0)
        }
    }
}
