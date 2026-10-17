import AppKit
import Observation
import SidelightCore
import os

/// Where a pinned app is now.
enum ResolvedApp: Equatable {
    /// At `url`, symbolic links resolved. `pathExists` is false when it was found by its bundle identifier instead,
    /// having moved since it was pinned.
    case found(URL, pathExists: Bool)
    /// Neither its path nor its bundle identifier lead to it: it was deleted, is on a disk that isn't there, or another
    /// app took its place.
    case missing

    var url: URL? {
        if case .found(let url, _) = self { url } else { nil }
    }
}

/// Which apps are running, for every App Launcher widget and the details panel.
///
/// It's told when apps launch and quit, and never checks on a timer: with nothing launching or quitting, it does
/// nothing at all. `NSWorkspace`'s list of running apps is observed (KVO), as its launch notification only covers
/// Dock apps, not menu-bar ones. Only what a launcher can show is published: Dock apps, and pinned menu-bar apps, so a
/// background helper starting doesn't redraw anything.
@Observable
final class AppLauncherService: DataService {
    /// Ends an observation.
    struct Subscription {
        let cancel: () -> Void
    }

    /// Where the running apps come from, and where apps are on disk; tests stand in their own.
    struct Source {
        var snapshot: () -> [RunningAppInfo]
        /// Calls `changed` on the main actor whenever the running apps change, and whenever a Dock app launches.
        var observe: (_ changed: @escaping @Sendable @MainActor () -> Void) -> Subscription
        /// Whether there's an app at the path, and its bundle identifier.
        var inspect: (_ path: String) -> (exists: Bool, bundleID: String?)
        /// Where the app with this bundle identifier is, if it's installed.
        var locate: (_ bundleID: String) -> URL?

        static var workspace: Source {
            let paths = BundlePaths()
            return Source(
                snapshot: { paths.snapshot() },
                observe: { changed in
                    let workspace = NSWorkspace.shared
                    let observation = workspace.observe(\.runningApplications, options: [.old, .new]) { _, _ in
                        MainActor.assumeIsolated { changed() }
                    }
                    // An app can be listed while it's still a background app, and become a Dock app a moment later.
                    let launch = workspace.notificationCenter.addObserver(
                        forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
                    ) { _ in
                        MainActor.assumeIsolated { changed() }
                    }
                    return Subscription {
                        observation.invalidate()
                        workspace.notificationCenter.removeObserver(launch)
                    }
                },
                inspect: { path in
                    let url = URL(filePath: path, directoryHint: .isDirectory)
                    guard FileManager.default.fileExists(atPath: path) else { return (false, nil) }
                    let plist = url.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
                    let info = NSDictionary(contentsOf: plist)
                    return (true, info?["CFBundleIdentifier"] as? String)
                },
                locate: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
        }
    }

    /// Dock apps, and the menu-bar apps a launcher pins. Assigned only when that changes.
    private(set) var running = RunningApps(apps: [])
    /// Apps being opened, for the launch pulse.
    private(set) var launching: Set<LauncherApp.ID> = []
    /// The launchers on screen and what they pin.
    var demand = AppLauncherDemand() {
        didSet {
            guard demand != oldValue else { return }
            if demand.pinned != oldValue.pinned { forgetResolved() }
            if isEnabled { publish() }
        }
    }
    /// Bumped whenever where apps are is looked up again, so views showing a missing app redraw.
    private var resolveGeneration = 0

    @ObservationIgnored private let source: Source
    @ObservationIgnored private var subscription: Subscription?
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var resolved: [LauncherApp.ID: (path: String, bundleID: String?, app: ResolvedApp)] =
        [:]
    @ObservationIgnored private var watchdogs: [LauncherApp.ID: DelayedTask] = [:]
    @ObservationIgnored private let ownBundleID = Bundle.main.bundleIdentifier

    /// How long an app counts as launching at most: Gatekeeper's first-launch question can hold it up for good.
    @ObservationIgnored private let launchWatchdog: Duration

    init(source: Source = .workspace, launchWatchdog: Duration = .seconds(10)) {
        self.source = source
        self.launchWatchdog = launchWatchdog
    }

    func start() {
        guard subscription == nil else { return }
        isEnabled = true
        // A moved or deleted app is noticed when the panel shows again.
        forgetResolved()
        subscription = source.observe { [weak self] in self?.publish() }
        publish()
    }

    /// Keeps what it read: the next start reads it again at once.
    func stop() {
        isEnabled = false
        subscription?.cancel()
        subscription = nil
        for watchdog in watchdogs.values { watchdog.cancel() }
        watchdogs = [:]
        if !launching.isEmpty { launching = [] }
    }

    private func publish() {
        let next = RunningApps(apps: source.snapshot()).filtered(for: demand)
        guard next != running else { return }
        // Apps usually relaunch after updating, which is when their icon changes.
        let previous = Set(running.apps.map(\.id))
        for info in next.apps where !previous.contains(info.id) {
            for key in demand.pinned
            where key.path == info.path || (key.bundleID != nil && key.bundleID == info.bundleID) {
                AppIcons.invalidate(path: key.path)
                if let path = info.path { AppIcons.invalidate(path: path) }
            }
        }
        Log.appLauncher.debug("Running apps changed: \(next.apps.count) shown")
        running = next
    }

    // MARK: Where apps are

    /// Where `app` is: at its path if the app there is still the same one, otherwise wherever its bundle identifier
    /// leads. Looked up once per app until the panel shows again or the pinned apps change, never on every draw.
    func resolve(_ app: LauncherApp) -> ResolvedApp {
        _ = resolveGeneration
        if let cached = resolved[app.id], cached.path == app.path, cached.bundleID == app.bundleID {
            return cached.app
        }
        let result = lookUp(app)
        resolved[app.id] = (app.path, app.bundleID, result)
        return result
    }

    private func lookUp(_ app: LauncherApp) -> ResolvedApp {
        let found = source.inspect(app.path)
        let url = URL(filePath: app.path, directoryHint: .isDirectory).resolvingSymlinksInPath()
        if found.exists, app.bundleID == nil || found.bundleID == app.bundleID {
            return .found(url, pathExists: true)
        }
        if let bundleID = app.bundleID, let moved = source.locate(bundleID) {
            return .found(moved.resolvingSymlinksInPath(), pathExists: false)
        }
        // Another app took its place: opening it would open the wrong app.
        return .missing
    }

    private func forgetResolved() {
        guard !resolved.isEmpty else { return }
        resolved = [:]
        resolveGeneration += 1
    }

    /// `app` as running apps are matched against it: at the path it resolves to.
    private func matchable(_ app: LauncherApp) -> (app: LauncherApp, pathExists: Bool) {
        guard case .found(let url, let pathExists) = resolve(app) else { return (app, true) }
        var app = app
        app.path = LauncherApp.standardize(url.path(percentEncoded: false))
        return (app, pathExists)
    }

    /// The running copies of `app`.
    func instances(of app: LauncherApp) -> [RunningAppInfo] {
        let (app, pathExists) = matchable(app)
        return running.instances(of: app, pathExists: pathExists)
    }

    func isRunning(_ app: LauncherApp) -> Bool {
        let (app, pathExists) = matchable(app)
        return running.isRunning(app, pathExists: pathExists)
    }

    /// Dock apps running that none of `pinned` is, in launch order, without Sidelight.
    func unpinned(excluding pinned: [LauncherApp]) -> [RunningAppInfo] {
        let matched = pinned.map(matchable)
        let existing = Set(matched.filter(\.pathExists).map(\.app.id))
        return running.unpinned(
            excluding: matched.map(\.app), ownBundleID: ownBundleID, pathExists: { existing.contains($0.id) })
    }

    // MARK: Launching

    /// Marks `id` as launching until ``finishLaunching(_:)``, or the watchdog. Returns false if it already is.
    @discardableResult
    func beginLaunching(_ id: LauncherApp.ID) -> Bool {
        guard !launching.contains(id) else { return false }
        launching.insert(id)
        let watchdog = DelayedTask()
        watchdog.schedule(after: launchWatchdog, tolerance: .seconds(1)) { [weak self] in
            self?.finishLaunching(id)
        }
        watchdogs[id] = watchdog
        return true
    }

    func finishLaunching(_ id: LauncherApp.ID) {
        watchdogs.removeValue(forKey: id)?.cancel()
        if launching.contains(id) { launching.remove(id) }
    }
}

/// The running apps' bundle paths, with symbolic links resolved, remembered by process so each is resolved once: a
/// pinned path and a running app's path have to compare equal, and Safari, for one, lives behind a link.
private final class BundlePaths {
    private var paths: [pid_t: String?] = [:]

    func snapshot() -> [RunningAppInfo] {
        let apps = NSWorkspace.shared.runningApplications
        var next: [pid_t: String?] = [:]
        let infos = apps.map { app in
            let pid = app.processIdentifier
            let path =
                paths[pid]
                ?? app.bundleURL.map {
                    LauncherApp.standardize($0.resolvingSymlinksInPath().path(percentEncoded: false))
                }
            next[pid] = path
            return RunningAppInfo(
                id: pid, bundleID: app.bundleIdentifier, path: path,
                name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "",
                isRegular: app.activationPolicy == .regular, isHidden: app.isHidden, launchDate: app.launchDate)
        }
        paths = next
        return infos
    }
}
