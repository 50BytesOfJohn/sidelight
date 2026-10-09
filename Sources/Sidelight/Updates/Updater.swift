import AppKit
import Observation
import SidelightCore
import Sparkle

/// Software updates through Sparkle, from the appcast at `SUFeedURL` in Info.plist.
///
/// Background checks use Sparkle's gentle reminders. Instead of an update window appearing over whatever the user
/// is doing, ``availableVersion`` is set and the menu bar icon shows a badge. Checks the user starts show Sparkle's
/// window right away. Debug builds never check, so `make dev` doesn't replace itself with a release.
@Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    /// The version a background check found, until the user looks at it.
    private(set) var availableVersion: String?
    /// False while a check or download is already under way, and always in debug builds.
    private(set) var canCheckForUpdates = false
    /// Called when the user changes a setting in Sparkle's own window, to keep `config.json` in step.
    @ObservationIgnored var onSettingsChange: ((UpdateSettings) -> Void)?

    let currentVersion: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }()

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var settings = UpdateSettings()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// Starts background checks. Safe to call twice.
    func start(with settings: UpdateSettings) {
        #if !DEBUG
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        apply(settings)
        controller.startUpdater()

        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.automaticDownloadsDidChange() }
            },
        ]
        #endif
    }

    /// Applies the user's settings from `config.json`.
    func apply(_ settings: UpdateSettings) {
        self.settings = settings
        guard let updater = controller?.updater else { return }
        // Each change restarts Sparkle's schedule, so only set what differs.
        if updater.automaticallyChecksForUpdates != settings.checksAutomatically {
            updater.automaticallyChecksForUpdates = settings.checksAutomatically
        }
        if updater.automaticallyDownloadsUpdates != settings.installsAutomatically {
            updater.automaticallyDownloadsUpdates = settings.installsAutomatically
        }
    }

    /// Shows Sparkle's window: the result of a new check, or the update a background check already found.
    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activateForcingForeground()
        controller.checkForUpdates(nil)
    }

    /// Sparkle's update window has its own "Automatically download and install updates" checkbox.
    private func automaticDownloadsDidChange() {
        guard let updater = controller?.updater, updater.automaticallyChecksForUpdates,
            updater.automaticallyDownloadsUpdates != settings.installsAutomatically
        else { return }
        settings.installsAutomatically = updater.automaticallyDownloadsUpdates
        onSettingsChange?(settings)
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows updates found right after launch itself; later ones wait for the user behind the badge.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if handleShowingUpdate {
            NSApp.activateForcingForeground()
        } else {
            availableVersion = update.displayVersionString
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}
