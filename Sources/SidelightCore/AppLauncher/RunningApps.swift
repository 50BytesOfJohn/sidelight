import Foundation

/// What Sidelight knows about one running app, copied off `NSRunningApplication`, which isn't a value.
public struct RunningAppInfo: Hashable, Sendable, Identifiable {
    /// The process identifier.
    public var id: Int32
    public var bundleID: String?
    /// Its bundle's path, standardized with symbolic links resolved.
    public var path: String?
    public var name: String
    /// A Dock app (`activationPolicy == .regular`), as opposed to a menu-bar app or a background one. Read when the
    /// list is taken: an app can start as one and become another a moment later.
    public var isRegular: Bool
    public var isHidden: Bool
    public var launchDate: Date?

    public init(
        id: Int32, bundleID: String?, path: String?, name: String, isRegular: Bool, isHidden: Bool = false,
        launchDate: Date? = nil
    ) {
        self.id = id
        self.bundleID = bundleID
        self.path = path
        self.name = name
        self.isRegular = isRegular
        self.isHidden = isHidden
        self.launchDate = launchDate
    }
}

/// The apps running now, and which of them are a launcher's.
public struct RunningApps: Hashable, Sendable {
    /// In launch order.
    public var apps: [RunningAppInfo]

    public init(apps: [RunningAppInfo]) {
        self.apps = apps
    }

    /// The running copies of `app`: those at its path. If its path no longer exists (`pathExists` false), the app was
    /// moved, and those with its bundle identifier count too.
    public func instances(of app: LauncherApp, pathExists: Bool) -> [RunningAppInfo] {
        apps.filter { Self.matches($0, app.key, byBundleID: !pathExists) }
    }

    public func isRunning(_ app: LauncherApp, pathExists: Bool) -> Bool {
        apps.contains { Self.matches($0, app.key, byBundleID: !pathExists) }
    }

    /// Regular apps none of `pinned` matches, in launch order, without Sidelight itself. `pathExists` says whether a
    /// pinned app's path exists; when it doesn't, its bundle identifier matches instead.
    public func unpinned(
        excluding pinned: [LauncherApp], ownBundleID: String?, pathExists: (LauncherApp) -> Bool = { _ in true }
    ) -> [RunningAppInfo] {
        let keys = pinned.map { (key: $0.key, byBundleID: !pathExists($0)) }
        return apps.filter { info in
            info.isRegular && (ownBundleID == nil || info.bundleID != ownBundleID)
                && !keys.contains { Self.matches(info, $0.key, byBundleID: $0.byBundleID) }
        }
    }

    /// Only what `demand` can show: regular apps, plus other ones a launcher pins. Comparing two filtered values decides
    /// whether anything a launcher shows changed.
    public func filtered(for demand: AppLauncherDemand) -> RunningApps {
        RunningApps(
            apps: apps.filter { info in
                info.isRegular || demand.pinned.contains { Self.matches(info, $0, byBundleID: true) }
            })
    }

    private static func matches(_ info: RunningAppInfo, _ key: LauncherAppKey, byBundleID: Bool) -> Bool {
        if let path = info.path, path == key.path { return true }
        guard byBundleID, let bundleID = key.bundleID else { return false }
        return info.bundleID == bundleID
    }
}
