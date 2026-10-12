import Foundation
import Observation
import SidelightCore
import os

/// Owns the live ``AppConfiguration`` and keeps it in sync with `config.json`.
///
/// - Changes are saved atomically after a short debounce.
/// - External edits to the file (it's meant to be hand-editable) are hot-reloaded.
/// - An unreadable file is moved aside rather than overwritten, so a typo never loses the user's setup.
/// - So is a file with values this version can't keep (out of range, unknown, from a newer version), before the
///   first save over it.
/// - When the file is edited while a change made in the app isn't saved yet, the app's change is saved and the edit
///   kept aside, rather than either silently replacing the other.
@Observable
final class ConfigurationStore {
    var configuration: AppConfiguration {
        didSet {
            guard configuration != oldValue, !isApplyingFileChange else { return }
            scheduleSave()
        }
    }

    let fileURL: URL

    /// What the file held when last read or written.
    @ObservationIgnored private var lastFileContents: Data?
    /// Whether ``lastFileContents`` says something ``configuration`` doesn't, so saving over it would lose it.
    @ObservationIgnored private var lastFileHasUnkeptValues = false
    @ObservationIgnored private var isApplyingFileChange = false
    @ObservationIgnored private let pendingSave = DelayedTask()
    @ObservationIgnored private let pendingReload = DelayedTask()
    @ObservationIgnored private var watcher: FileWatcher?

    static let saveDelay: Duration = .milliseconds(300)
    static let reloadDelay: Duration = .milliseconds(150)

    /// Debug builds (`make dev`) keep their own configuration, so trying changes never touches the installed app's.
    static var defaultFileURL: URL {
        #if DEBUG
        let directory = "Sidelight Dev"
        #else
        let directory = "Sidelight"
        #endif
        return URL.applicationSupportDirectory.appending(path: "\(directory)/config.json", directoryHint: .notDirectory)
    }

    init(fileURL: URL = ConfigurationStore.defaultFileURL) {
        self.fileURL = fileURL
        configuration = AppConfiguration()

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            Log.configuration.error("Can't create the configuration directory: \(error)")
        }
        load()
    }

    /// Starts hot-reloading external edits to the configuration file.
    func startWatchingFile() {
        guard watcher == nil else { return }
        watcher = FileWatcher(file: fileURL) { [weak self] in self?.scheduleReload() }
    }

    /// Writes any pending change immediately (e.g. right before the app quits).
    func flush() {
        guard pendingSave.isPending else { return }
        pendingSave.cancel()
        save()
    }

    // MARK: Loading

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            Log.configuration.info("No configuration file yet; writing defaults")
            save()
            return
        } catch {
            Log.configuration.error("Can't read the configuration file, using defaults: \(error)")
            return
        }

        do {
            applyFromFile(try AppConfiguration(json: data), contents: data)
        } catch {
            Log.configuration.error("Configuration file is invalid, using defaults: \(error)")
            save()
        }
    }

    /// Adopts a configuration read from disk without scheduling a save of it.
    private func applyFromFile(_ configuration: AppConfiguration, contents: Data) {
        lastFileContents = contents
        lastFileHasUnkeptValues = !Self.keepsEveryValue(of: contents, in: configuration)
        if lastFileHasUnkeptValues {
            Log.configuration.notice("The configuration file has values this version changes; kept aside on save")
        }
        isApplyingFileChange = true
        self.configuration = configuration
        isApplyingFileChange = false
    }

    /// Whether the file can be saved over: it is missing, or it holds what was last read or written and every value it
    /// has would be kept. Otherwise it is kept aside first: an invalid file (found at launch, or a hand edit not yet
    /// fixed), one with values reading it changes or drops, or an edit not reloaded yet that the save would undo. A
    /// file that exists but can't be read can't be kept aside either, so it is left alone.
    private func mayReplaceFile() -> Bool {
        let onDisk: Data
        do {
            onDisk = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return true
        } catch {
            Log.configuration.error("Not saving: can't read the existing configuration file to keep it safe: \(error)")
            return false
        }
        if onDisk == lastFileContents {
            guard lastFileHasUnkeptValues else { return true }
            lastFileHasUnkeptValues = !backUp(onDisk, as: "unsupported")
            return !lastFileHasUnkeptValues
        }
        guard let edited = try? AppConfiguration(json: onDisk) else { return backUp(onDisk, as: "invalid") }
        guard Self.keepsEveryValue(of: onDisk, in: edited) else { return backUp(onDisk, as: "unsupported") }
        // Only reformatted, or already what's being saved: replacing it loses nothing.
        let lastRead = lastFileContents.flatMap { try? AppConfiguration(json: $0) }
        guard edited != configuration, edited != lastRead else { return true }
        return backUp(onDisk, as: "external-edit")
    }

    /// Keeps a file about to be replaced next to the configuration, named for why and when, so an earlier backup is
    /// never replaced. Returns whether it was kept.
    private func backUp(_ data: Data, as reason: String) -> Bool {
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacing(":", with: "-")
        for attempt in 1...20 {
            let name = attempt == 1 ? "\(reason)-\(stamp)" : "\(reason)-\(stamp)-\(attempt)"
            let backup = fileURL.deletingPathExtension().appendingPathExtension("\(name).json")
            do {
                try data.write(to: backup, options: .withoutOverwriting)
                Log.configuration.notice(
                    "Kept the \(reason, privacy: .public) configuration as \(backup.lastPathComponent, privacy: .public)"
                )
                return true
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                Log.configuration.fault("Can't back up the \(reason, privacy: .public) configuration: \(error)")
                return false
            }
        }
        return false
    }

    /// Whether saving `configuration`, read from `contents`, keeps every value the file has. Options it leaves out
    /// take their defaults and don't count, nor do whitespace or key order; a value moved into range, one only a newer
    /// version knows, or a retired widget does.
    private static func keepsEveryValue(of contents: Data, in configuration: AppConfiguration) -> Bool {
        guard let file = try? JSONSerialization.jsonObject(with: contents),
            let saved = try? JSONSerialization.jsonObject(with: configuration.json())
        else { return false }
        let kept = values(in: saved)
        return values(in: file).allSatisfy { path, value in value == NSNull() || kept[path] == value }
    }

    /// Every value in a JSON document, by its path, such as `sections.<id>.widgets.<id>.settings.style`. Elements
    /// with an `id` are found by it, so a dropped widget doesn't move the ones after it.
    private static func values(in json: Any, at path: String = "") -> [String: NSObject] {
        func child(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }
        switch json {
        case let object as [String: Any]:
            return object.reduce(into: [:]) { $0.merge(values(in: $1.value, at: child($1.key))) { $1 } }
        case let array as [Any]:
            return array.enumerated().reduce(into: [:]) { result, element in
                let key = ((element.element as? [String: Any])?["id"] as? String) ?? "\(element.offset)"
                result.merge(values(in: element.element, at: child(key))) { $1 }
            }
        default:
            return [path: json as? NSObject ?? NSNull()]
        }
    }

    // MARK: Saving

    private func scheduleSave() {
        pendingSave.schedule(after: Self.saveDelay) { [weak self] in self?.save() }
    }

    private func save() {
        do {
            let data = try configuration.json()
            guard data != lastFileContents, mayReplaceFile() else { return }
            try data.write(to: fileURL, options: .atomic)
            lastFileContents = data
            lastFileHasUnkeptValues = false
        } catch {
            Log.configuration.error("Can't save the configuration: \(error)")
        }
    }

    // MARK: Hot reload

    private func scheduleReload() {
        pendingReload.schedule(after: Self.reloadDelay) { [weak self] in self?.reloadIfChangedExternally() }
    }

    private func reloadIfChangedExternally() {
        guard let data = try? Data(contentsOf: fileURL), data != lastFileContents else { return }
        // Adopting the edit would drop a change made in the app and not saved yet: save that instead, which keeps the
        // edit aside (see `mayReplaceFile()`).
        guard !pendingSave.isPending else {
            Log.configuration.notice("The configuration file was edited while a change in the app was unsaved")
            flush()
            return
        }
        do {
            applyFromFile(try AppConfiguration(json: data), contents: data)
            Log.configuration.info("Reloaded the configuration file after an external edit")
        } catch {
            // Likely mid-edit: the next valid save of it applies. A change made in the app before then is saved over
            // it, and the edit kept aside first (see `mayReplaceFile()`).
            Log.configuration.error("Ignoring an invalid edit to the configuration file: \(error)")
        }
    }
}
