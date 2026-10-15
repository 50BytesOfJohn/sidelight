import Foundation
import Observation
import SidelightCore
import Synchronization
import os

/// Owns the stash and keeps it in `stash/items.json`, next to `config.json`. One store for every display and every Stash
/// widget, and the only writer of the file.
///
/// - Changes are saved atomically after a short debounce, and flushed before the app quits. Encoding and writing run
///   off the main actor, one snapshot at a time, in order (see ``StashFileWriter``). The editor writes through: every
///   change it makes goes straight into the list, and the debounce batches the writes.
/// - A save that fails is tried again a little later, and on every change and flush until one succeeds. Meanwhile
///   ``hasSaveFailed`` says so, for the widget, the panel and captures to show.
/// - Done items are deleted ``deleteDoneAfter`` after they were done, as the stash loads, changes or its panel opens:
///   never on a timer, so an idle stash costs nothing.
/// - The file isn't watched: nothing else writes it, and nothing runs until someone changes the stash.
/// - A file that's there but can't be read (its permissions, say) is never saved over, as `config.json` isn't: the
///   stash works in memory, saying it isn't saved, and reads the file again before each save. Once it can, what's on
///   disk comes first and what was stashed meanwhile follows.
/// - An invalid file is moved aside rather than overwritten. So is a copy of a file holding something this version
///   can't keep (a later version's format, an item it can't read), before the first save over it.
/// - Nothing logged ever includes an item's text.
@Observable
final class StashStore {
    /// Why ``add(_:source:)`` didn't take text in.
    enum Refusal: Error {
        /// Nothing but whitespace.
        case blank
        /// Longer than ``StashList/maximumTextLength``.
        case tooLong
    }

    private(set) var list = StashList()
    /// The last save failed, or the file can't be read so nothing is saved over it: what's stashed since is kept only
    /// while Sidelight runs, until a save goes through.
    private(set) var hasSaveFailed = false
    /// Which end of the queue open items are listed from. Only how they're listed: the queue itself never changes for it.
    var order = StashOrder.oldestFirst
    /// How long done items are kept; `nil` keeps them. Changing it deletes those done longer ago straight away.
    @ObservationIgnored var deleteDoneAfter: TimeInterval? {
        didSet { if deleteDoneAfter != oldValue { deleteExpiredDone() } }
    }

    let fileURL: URL

    /// Writes the file; `nil` while it's there but can't be read, so the stash is in memory only and nothing is saved
    /// over the file.
    @ObservationIgnored private var writer: StashFileWriter?
    /// ``list`` has changes no write has saved yet: set by every change, cleared when a write is handed a snapshot,
    /// and set again if that write fails.
    @ObservationIgnored private var hasUnsavedChanges = false
    @ObservationIgnored private let pendingSave = DelayedTask()

    static let saveDelay: Duration = .milliseconds(300)
    /// How long after a failed save it's tried again, unless a change or a flush comes first.
    static let retryDelay: Duration = .seconds(30)

    init(fileURL: URL, deleteDoneAfter: TimeInterval?) {
        self.fileURL = fileURL
        self.deleteDoneAfter = deleteDoneAfter
        let (list, state) = Self.load(from: fileURL)
        self.list = list
        writer = state.map { StashFileWriter(fileURL: fileURL, state: $0) }
        hasSaveFailed = writer == nil
        deleteExpiredDone()
    }

    /// Reads the file again if it couldn't be read. Once it can, its items come first and what was stashed in memory
    /// meanwhile follows, saved soon after; the file is handled as on launch, never replaced unread.
    func retryReading() {
        guard writer == nil else { return }
        let (loaded, state) = Self.load(from: fileURL)
        guard let state else { return }
        Log.stash.notice("The stash file can be read again")
        var merged = loaded
        for item in list.items { merged.restore(item, at: merged.items.count) }
        writer = StashFileWriter(fileURL: fileURL, state: state)
        setSaveFailed(false)
        if merged != list { list = merged }
        if hasUnsavedChanges { pendingSave.schedule(after: Self.saveDelay) { [weak self] in self?.save() } }
        deleteExpiredDone()
    }

    /// Writes the stash now, after any write under way, and waits for it (e.g. right before the app quits, or to try
    /// a failed save again). Costs next to nothing when the file already holds it.
    func flush() {
        pendingSave.cancel()
        retryReading()
        guard let writer else { return }
        let isSaved = writer.writeNow(list)
        hasUnsavedChanges = !isSaved
        setSaveFailed(!isSaved)
    }

    /// Open items as the widgets list them, in ``order``.
    var openItems: [StashItem] { list.openItems(order) }

    // MARK: Changing the stash

    /// Adds `text` at the end of the queue; returns the item, or why it wasn't added. A file that couldn't be read is
    /// read again first, so a capture says whether it's saved as of now.
    @discardableResult
    func add(_ text: String, source: String? = nil) -> Result<StashItem, Refusal> {
        guard !StashList.isTooLong(text) else { return .failure(.tooLong) }
        retryReading()
        var added: StashItem?
        change {
            added = $0.add(text, source: source, now: .now)
            return added != nil
        }
        guard let added else { return .failure(.blank) }
        Log.stash.info("Stashed an item")
        return .success(added)
    }

    /// Replaces the item's text; blank text, and text too long, leave it as it was.
    func setText(_ text: String, of id: StashItem.ID) {
        change { $0.setText(text, of: id, now: .now) }
    }

    func setPinned(_ isPinned: Bool, _ id: StashItem.ID) {
        change { $0.setPinned(isPinned, id, now: .now) }
    }

    func markDone(_ id: StashItem.ID) {
        change { $0.markDone(id, now: .now) }
    }

    func reopen(_ id: StashItem.ID) {
        change { $0.reopen(id, now: .now) }
    }

    func move(_ id: StashItem.ID, toPlaceOf target: StashItem.ID) {
        change { $0.move(id, toPlaceOf: target) }
    }

    func move(_ id: StashItem.ID, by offset: Int, among listed: [StashItem.ID]) {
        change { $0.move(id, by: offset, among: listed) }
    }

    /// Deletes the item; returns it and where it was, to put back with ``restore(_:at:)``.
    @discardableResult
    func delete(_ id: StashItem.ID) -> (item: StashItem, index: Int)? {
        var removed: (item: StashItem, index: Int)?
        change {
            removed = $0.remove(id)
            return removed != nil
        }
        return removed
    }

    /// Puts a deleted item back at `index`, as undoing its deletion does.
    func restore(_ item: StashItem, at index: Int) {
        change {
            let count = $0.items.count
            $0.restore(item, at: index)
            return $0.items.count != count
        }
    }

    /// Deletes the items done longer ago than ``deleteDoneAfter``. Every change does too; nothing runs on a timer
    /// for it, so this is for the moments the stash is looked at (loading it, opening the panel).
    func deleteExpiredDone() {
        change { _ in false }
    }

    /// Applies `body` to a copy, deleting what's been done too long, and publishes and saves it only when that
    /// changed something, so a change that does nothing redraws nothing.
    private func change(_ body: (inout StashList) -> Bool) {
        var copy = list
        let changed = body(&copy)
        let expired = deleteDoneAfter.map { copy.removeDone(before: .now - $0) } ?? false
        guard changed || expired else { return }
        list = copy
        hasUnsavedChanges = true
        pendingSave.schedule(after: Self.saveDelay) { [weak self] in self?.save() }
    }

    // MARK: The file

    /// Hands the writer a snapshot of the list, to write after any write before it.
    private func save() {
        retryReading()
        guard hasUnsavedChanges, let writer else { return }
        hasUnsavedChanges = false
        writer.write(list) { [weak self] isSaved in self?.finishedWrite(isSaved: isSaved) }
    }

    private func finishedWrite(isSaved: Bool) {
        setSaveFailed(!isSaved)
        guard !isSaved else { return }
        hasUnsavedChanges = true
        // Unless a change comes first, which saves sooner.
        if !pendingSave.isPending {
            pendingSave.schedule(after: Self.retryDelay) { [weak self] in self?.save() }
        }
    }

    private func setSaveFailed(_ hasFailed: Bool) {
        if hasSaveFailed != hasFailed { hasSaveFailed = hasFailed }
    }

    /// Reads the stash, and what saving over the file has to know about it: `nil` when the file is there but can't be
    /// read (nor kept aside), so nothing may be saved over it.
    private static func load(from fileURL: URL) -> (StashList, StashFileWriter.State?) {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            // Written the first time something is stashed.
            return (StashList(), StashFileWriter.State())
        } catch {
            Log.stash.error("Can't read the stash file; not saving over it: \(error)")
            return (StashList(), nil)
        }
        do {
            let list = try StashList(json: data)
            if list.droppedOnLoad {
                Log.stash.notice("The stash file has items or a format this version can't keep; kept aside on save")
            }
            return (
                list, StashFileWriter.State(saved: list, mustKeepFileBeforeSaving: list.droppedOnLoad)
            )
        } catch {
            // Moved aside now, so it isn't mistaken for the stash again, and the next save starts a new file.
            Log.stash.error("The stash file is invalid; keeping it aside and starting empty: \(error)")
            guard StashFileWriter.keepFile(data, besides: fileURL, as: "invalid") else {
                return (StashList(), nil)
            }
            try? FileManager.default.removeItem(at: fileURL)
            return (StashList(), StashFileWriter.State())
        }
    }
}

/// Encodes and writes the stash file off the main actor, one snapshot at a time, in the order they're handed over.
///
/// A serial queue rather than an actor: snapshots are queued the moment they're handed over, so they're written in
/// that order, and quitting can wait for the last write from the main thread (`writeNow(_:)`) without needing the
/// main actor back. Outcomes go back through the main queue, so they arrive in that order too.
private nonisolated final class StashFileWriter: Sendable {
    /// What the writer knows about the file.
    nonisolated struct State {
        /// The stash the file holds as far as this version reads it (empty while there's no file), as last read or
        /// written. A list equal to it isn't written, so a stash nobody changed never rewrites its file: no empty file
        /// for someone who never stashes, and a later version's file is left alone until something changes.
        var saved = StashList()
        /// The file has something this version would drop: kept aside before the first save over it.
        var mustKeepFileBeforeSaving = false
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "Sidelight.StashFileWriter", qos: .utility)
    /// Only touched on `queue`; the lock is what lets the compiler check that the writer is safe to share.
    private let state: Mutex<State>

    init(fileURL: URL, state: State) {
        self.fileURL = fileURL
        self.state = Mutex(state)
    }

    /// Writes `list` once every write handed over before it is done, then reports whether it's saved on the main
    /// thread.
    func write(_ list: StashList, then report: @escaping @MainActor (Bool) -> Void) {
        queue.async {
            let isSaved = self.writeOnQueue(list)
            DispatchQueue.main.async { report(isSaved) }
        }
    }

    /// Writes `list` after every write handed over before it, waiting for it all. Returns whether it's saved.
    func writeNow(_ list: StashList) -> Bool {
        queue.sync { writeOnQueue(list) }
    }

    /// Returns whether the file holds `list`: written, or it already did.
    private func writeOnQueue(_ list: StashList) -> Bool {
        state.withLock { state in
            do {
                guard list != state.saved else { return true }
                let data = try list.json()
                if state.mustKeepFileBeforeSaving {
                    // Kept aside before anything replaces it. If that can't be done, nothing does.
                    do {
                        let onDisk = try Data(contentsOf: fileURL)
                        guard Self.keepFile(onDisk, besides: fileURL, as: "unsupported") else { return false }
                    } catch CocoaError.fileReadNoSuchFile {
                        // Gone since it was read: nothing left to keep.
                    }
                    state.mustKeepFileBeforeSaving = false
                }
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                state.saved = list
                return true
            } catch {
                Log.stash.error("Can't save the stash: \(error)")
                return false
            }
        }
    }

    /// Keeps `data` beside the stash file; returns whether it was kept.
    static func keepFile(_ data: Data, besides fileURL: URL, as reason: String) -> Bool {
        do {
            let backup = try FileBackup.keep(data, besides: fileURL, as: reason)
            Log.stash.notice(
                "Kept the \(reason, privacy: .public) stash file as \(backup.lastPathComponent, privacy: .public)")
            return true
        } catch {
            Log.stash.fault("Can't keep the \(reason, privacy: .public) stash file aside: \(error)")
            return false
        }
    }
}
