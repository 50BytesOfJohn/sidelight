import Foundation
import Observation
import SidelightCore
import os

/// Recent chats in the Cursor editor and its Agents window, from the chat list Cursor keeps in its global state
/// database (see ``CursorChatIndex``). No setup, no sign-in and nothing sent anywhere: names, folders and times only.
///
/// Cursor keeps no live status there, so chats are listed by when they last changed, never as working or waiting.
/// The database's folder is watched with FSEvents; Cursor writes to it many times a minute while it's in use, so
/// changes are gathered for a while before one small read, and nothing runs while Cursor is quiet.
@Observable
final class CursorChatsService {
    nonisolated static let database = CursorChatIndex.defaultDatabase
    nonisolated static let storageDirectory = database.deletingLastPathComponent()
    /// Chats are listed for up to this long after they last changed; each widget shows less.
    nonisolated static let lookback: TimeInterval = 24 * 60 * 60
    /// FSEvents gathers a burst of writes for this long before telling us. A chat list without live status doesn't
    /// need to be any fresher.
    static let eventLatency: TimeInterval = 10
    /// How often to look for Cursor while it isn't found.
    static let missingSweepInterval: Duration = .seconds(120)

    enum Availability: Equatable {
        case found
        /// No state database: Cursor isn't installed, or hasn't run.
        case notFound
        /// A Cursor without the chat list this version reads.
        case unsupported
        /// The last read failed, such as when the file isn't readable; the chats read before it, if any, stay.
        case unreadable
    }

    /// Newest first, from the last day.
    private(set) var chats: [CursorChat] = []
    /// The chat list has been read at least once.
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
        guard watcher == nil,
            FileManager.default.fileExists(atPath: Self.storageDirectory.path(percentEncoded: false))
        else { return }
        watcher = FileEventStream(directory: Self.storageDirectory, latency: Self.eventLatency, queue: .main) {
            [weak self] in
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
        let result = await Self.read(now: .now)
        guard isEnabled, !Task.isCancelled, generation == reloadGeneration else { return }
        hasLoaded = true
        switch result {
        case .success(let read):
            availability = .found
            if read != chats { chats = read }
        case .failure(.unreadable):
            // Often mid-write, so the chats read last stay, and the next change reads it again. Until then it says
            // so rather than passing an unread list for an empty one.
            Log.cursor.info("Couldn't read Cursor's chat list this time")
            availability = .unreadable
        case .failure(.noDatabase):
            if availability != .notFound {
                Log.cursor.notice("No Cursor state database at \(Self.databasePath, privacy: .public)")
            }
            availability = .notFound
            if !chats.isEmpty { chats = [] }
        case .failure(.unsupported):
            if availability != .unsupported { Log.cursor.notice("Cursor's state database has no chat list") }
            availability = .unsupported
            if !chats.isEmpty { chats = [] }
        }
        updateSweep(needed: availability == .notFound)
    }

    /// While Cursor isn't found, its folder is looked for now and then: FSEvents can't watch a folder that doesn't
    /// exist yet.
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

    private nonisolated static var databasePath: String { database.path(percentEncoded: false) }

    @concurrent
    private static func read(now: Date) async -> Result<[CursorChat], CursorChatIndex.Failure> {
        CursorChatIndex.chats(updatedSince: now.addingTimeInterval(-lookback), in: database)
    }
}
