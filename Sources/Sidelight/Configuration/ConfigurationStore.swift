import Foundation
import Observation
import SidelightCore
import os

/// Owns the live ``AppConfiguration`` and keeps it in sync with `config.json`.
///
/// - Changes are saved atomically after a short debounce.
/// - External edits to the file (it's meant to be hand-editable) are hot-reloaded.
/// - An unreadable file is moved aside rather than overwritten, so a typo never loses the user's setup.
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
        isApplyingFileChange = true
        self.configuration = configuration
        isApplyingFileChange = false
    }

    /// Whether the file can be saved over: it is missing, holds what was last read or written, or something readable,
    /// or an invalid file (found at launch, or a hand edit not yet fixed) has been kept aside first. A file that
    /// exists but can't be read can't be kept aside either, so it is left alone.
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
        guard onDisk != lastFileContents, (try? AppConfiguration(json: onDisk)) == nil else { return true }
        return backUpInvalidFile(onDisk)
    }

    /// Keeps an unreadable file next to the configuration, named for when it was found, so an earlier backup is
    /// never replaced. Returns whether it was kept.
    private func backUpInvalidFile(_ data: Data) -> Bool {
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacing(":", with: "-")
        for attempt in 1...20 {
            let name = attempt == 1 ? "invalid-\(stamp)" : "invalid-\(stamp)-\(attempt)"
            let backup = fileURL.deletingPathExtension().appendingPathExtension("\(name).json")
            do {
                try data.write(to: backup, options: .withoutOverwriting)
                Log.configuration.notice(
                    "Moved the invalid configuration to \(backup.lastPathComponent, privacy: .public)")
                return true
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                Log.configuration.fault("Can't back up the invalid configuration: \(error)")
                return false
            }
        }
        return false
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
