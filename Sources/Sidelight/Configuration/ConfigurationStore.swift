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

    @ObservationIgnored private var lastFileContents: Data?
    @ObservationIgnored private var isApplyingFileChange = false
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var pendingReload: Task<Void, Never>?
    @ObservationIgnored private var watcher: FileWatcher?

    static let saveDelay: Duration = .milliseconds(300)
    static let reloadDelay: Duration = .milliseconds(150)

    static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Sidelight/config.json", directoryHint: .notDirectory)
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
        watcher = FileWatcher(file: fileURL, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
    }

    /// Writes any pending change immediately (e.g. right before the app quits).
    func flush() {
        guard let pendingSave else { return }
        pendingSave.cancel()
        self.pendingSave = nil
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
            backUpInvalidFile(data)
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

    private func backUpInvalidFile(_ data: Data) {
        let backup = fileURL.deletingPathExtension().appendingPathExtension("invalid.json")
        do {
            try data.write(to: backup, options: .atomic)
            Log.configuration.notice(
                "Moved the invalid configuration to \(backup.lastPathComponent, privacy: .public)")
        } catch {
            Log.configuration.error("Can't back up the configuration: \(error)")
        }
    }

    // MARK: Saving

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: Self.saveDelay) } catch { return }
            self?.pendingSave = nil
            self?.save()
        }
    }

    private func save() {
        do {
            let data = try configuration.json()
            guard data != lastFileContents else { return }
            try data.write(to: fileURL, options: .atomic)
            lastFileContents = data
        } catch {
            Log.configuration.error("Can't save the configuration: \(error)")
        }
    }

    // MARK: Hot reload

    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            do { try await Task.sleep(for: Self.reloadDelay) } catch { return }
            self?.reloadIfChangedExternally()
        }
    }

    private func reloadIfChangedExternally() {
        guard let data = try? Data(contentsOf: fileURL), data != lastFileContents else { return }
        do {
            applyFromFile(try AppConfiguration(json: data), contents: data)
            Log.configuration.info("Reloaded the configuration file after an external edit")
        } catch {
            Log.configuration.error("Ignoring an invalid edit to the configuration file: \(error)")
        }
    }
}
