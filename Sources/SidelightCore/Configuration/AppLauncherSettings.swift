import Foundation

/// One pinned app. Found by its path first, then by its bundle identifier, so a moved or renamed app is still found
/// and two copies with one identifier (Xcode, Xcode-beta) stay two.
public struct LauncherApp: Codable, Hashable, Sendable, Identifiable {
    /// The configuration file tells list entries apart by `id`, so one unreadable entry doesn't shift the others.
    public var id: UUID
    /// The standardized absolute path of the `.app`, as pinned.
    public var path: String
    /// `nil` for the rare app without one.
    public var bundleID: String?
    /// Its name when pinned, shown while it can't be found.
    public var name: String

    public init(id: UUID = UUID(), path: String, bundleID: String?, name: String) {
        self.id = id
        self.path = Self.standardize(path)
        self.bundleID = bundleID.flatMap { $0.isEmpty ? nil : $0 }
        self.name = name
    }

    /// The id, path and name are required; a bundle identifier that can't be read is taken for none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            path: try container.decode(String.self, forKey: .path),
            bundleID: container.decodeLeniently(.bundleID, or: nil),
            name: try container.decode(String.self, forKey: .name))
    }

    /// `path` without `.`, `..`, `~` or a trailing slash, so two spellings of one place compare equal. Symbolic links
    /// are left alone: resolving them needs the disk.
    public static func standardize(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    public var key: LauncherAppKey { LauncherAppKey(path: path, bundleID: bundleID) }
}

/// How far apart a launcher's icons are.
public enum LauncherSpacing: String, Codable, CaseIterable, Identifiable, Sendable {
    case tight, regular, roomy

    public var id: Self { self }

    /// The gap between icons in the regular layout.
    public var points: Double {
        switch self {
        case .tight: 4
        case .regular: 8
        case .roomy: 12
        }
    }

    /// The gap in the compact layout, which has less room.
    public var compactPoints: Double { (points * 0.75).rounded() }
}

/// What one App Launcher widget shows: its pinned apps, and how they're laid out.
public struct AppLauncherSettings: Codable, Hashable, Sendable {
    /// What the settings editor offers for ``iconSize``.
    public static let iconSizeChoices = [24, 28, 32, 40, 48, 56]
    public static let iconSizeRange = 16...64
    /// 0: as many as fit.
    public static let columnRange = 0...12
    /// 0: every app.
    public static let rowRange = 0...12
    public static let barCountRange = 1...20

    public var apps: [LauncherApp] = []
    /// Regular layout. Compact draws min(iconSize, 28), minimal 32 (or 28 when the column is narrow), and the bar 24.
    public var iconSize = 32
    public var spacing = LauncherSpacing.regular
    /// Columns in regular and compact; 0 fits as many as the width allows. More than fit is reduced to what does.
    public var columns = 0
    /// Rows shown in regular and compact; 0 shows every app. Also caps the minimal layout's single column.
    public var rows = 0
    /// Icons in the bar layout, before the All-apps tile.
    public var barCount = 8
    /// Names under icons, in the regular layout only.
    public var showsNames = false
    public var showsRunningIndicator = true
    /// Running apps that aren't pinned, after a divider, as the Dock shows them.
    public var showsRunningApps = false
    public var showsAllAppsTile = true

    public init(
        apps: [LauncherApp] = [], iconSize: Int = 32, spacing: LauncherSpacing = .regular, columns: Int = 0,
        rows: Int = 0, barCount: Int = 8, showsNames: Bool = false, showsRunningIndicator: Bool = true,
        showsRunningApps: Bool = false, showsAllAppsTile: Bool = true
    ) {
        self.apps = apps
        self.iconSize = iconSize
        self.spacing = spacing
        self.columns = columns
        self.rows = rows
        self.barCount = barCount
        self.showsNames = showsNames
        self.showsRunningIndicator = showsRunningIndicator
        self.showsRunningApps = showsRunningApps
        self.showsAllAppsTile = showsAllAppsTile
    }

    /// Missing or unreadable options take their defaults, hand-edited numbers are moved into the ranges the editor
    /// offers, and an app that can't be read, or is pinned twice, is dropped rather than the whole widget.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppLauncherSettings()
        let apps = container.decodeLeniently(.apps, or: [LenientElement<LauncherApp>]()).compactMap(\.value)
        var paths = Set<String>()
        var ids = Set<UUID>()
        self.apps = apps.filter { paths.insert($0.path).inserted && ids.insert($0.id).inserted }
        iconSize = container.decodeLeniently(.iconSize, or: defaults.iconSize).clamped(to: Self.iconSizeRange)
        spacing = container.decodeLeniently(.spacing, or: defaults.spacing)
        columns = container.decodeLeniently(.columns, or: defaults.columns).clamped(to: Self.columnRange)
        rows = container.decodeLeniently(.rows, or: defaults.rows).clamped(to: Self.rowRange)
        barCount = container.decodeLeniently(.barCount, or: defaults.barCount).clamped(to: Self.barCountRange)
        showsNames = container.decodeLeniently(.showsNames, or: defaults.showsNames)
        showsRunningIndicator = container.decodeLeniently(
            .showsRunningIndicator, or: defaults.showsRunningIndicator)
        showsRunningApps = container.decodeLeniently(.showsRunningApps, or: defaults.showsRunningApps)
        showsAllAppsTile = container.decodeLeniently(.showsAllAppsTile, or: defaults.showsAllAppsTile)
    }

    /// Adds the apps not already pinned (see ``isPinned(path:bundleID:pathExists:)``), at `index` or at the end, in
    /// their order. Returns how many were added.
    @discardableResult
    public mutating func add(
        _ apps: [LauncherApp], at index: Int? = nil,
        pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Int {
        var added: [LauncherApp] = []
        for app in apps {
            let current = AppLauncherSettings(apps: self.apps + added)
            guard !current.isPinned(path: app.path, bundleID: app.bundleID, pathExists: pathExists) else { continue }
            added.append(app)
        }
        let at = (index ?? self.apps.count).clamped(to: 0...self.apps.count)
        self.apps.insert(contentsOf: added, at: at)
        return added.count
    }

    public mutating func remove(_ id: LauncherApp.ID) {
        apps.removeAll { $0.id == id }
    }

    /// As `List.onMove` reports a move.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.filter(apps.indices.contains).map { apps[$0] }
        let before = source.count { $0 < destination }
        apps = apps.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        apps.insert(contentsOf: moving, at: (destination - before).clamped(to: 0...apps.count))
    }

    /// Whether an app at `path` is pinned already: one is at the same path, or has the same bundle identifier and
    /// its own path no longer exists (it was moved, and this is where it went).
    public func isPinned(
        path: String, bundleID: String?,
        pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        let path = LauncherApp.standardize(path)
        return apps.contains { app in
            if app.path == path { return true }
            guard let bundleID, app.bundleID == bundleID else { return false }
            return !pathExists(app.path)
        }
    }

    /// What previews show in place of an empty launcher: apps every Mac has.
    public static let sample = AppLauncherSettings(
        apps: [
            ("/System/Library/CoreServices/Finder.app", "com.apple.finder", "Finder"),
            ("/Applications/Safari.app", "com.apple.Safari", "Safari"),
            ("/System/Applications/Utilities/Terminal.app", "com.apple.Terminal", "Terminal"),
            ("/System/Applications/Mail.app", "com.apple.mail", "Mail"),
            ("/System/Applications/Notes.app", "com.apple.Notes", "Notes"),
            ("/System/Applications/Calendar.app", "com.apple.iCal", "Calendar"),
            ("/System/Applications/Music.app", "com.apple.Music", "Music"),
            ("/System/Applications/System Settings.app", "com.apple.systempreferences", "System Settings"),
        ]
        .enumerated()
        .map { index, app in
            // Fixed ids, so previews don't redraw as new apps.
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1)) ?? UUID()
            return LauncherApp(id: id, path: app.0, bundleID: app.1, name: app.2)
        })
}

/// Where a pinned app is looked for: its path, then its bundle identifier.
public struct LauncherAppKey: Hashable, Sendable {
    public var path: String
    public var bundleID: String?

    public init(path: String, bundleID: String?) {
        self.path = path
        self.bundleID = bundleID
    }
}

/// What the App Launcher service has to do for the launchers on screen and the details panel.
public struct AppLauncherDemand: Equatable, Sendable {
    /// A launcher widget, or its details panel, is on screen.
    public var isShown = false
    /// Pinned apps across every shown launcher. Menu-bar apps are tracked only if pinned, which keeps redraws to
    /// what's shown.
    public var pinned: Set<LauncherAppKey> = []
    /// Running apps that aren't pinned are listed somewhere: a widget showing them, or the details panel.
    public var listsRunning = false

    public init(isShown: Bool = false, pinned: Set<LauncherAppKey> = [], listsRunning: Bool = false) {
        self.isShown = isShown
        self.pinned = pinned
        self.listsRunning = listsRunning
    }

    public var isEmpty: Bool { !isShown }

    public mutating func merge(_ other: AppLauncherDemand) {
        isShown = isShown || other.isShown
        pinned.formUnion(other.pinned)
        listsRunning = listsRunning || other.listsRunning
    }
}

extension AppConfiguration {
    /// Edits the launcher with `id` in place; does nothing if it was removed meanwhile, or isn't a launcher.
    public mutating func updateAppLauncher(_ id: WidgetInstance.ID, _ change: (inout AppLauncherSettings) -> Void) {
        updateWidget(id) { widget in
            guard case .appLauncher(var settings) = widget.settings else { return }
            change(&settings)
            widget.settings = .appLauncher(settings)
        }
    }

    /// What the launchers among `widgets` show.
    public func appLauncherDemand(of widgets: some Sequence<WidgetInstance>) -> AppLauncherDemand {
        var demand = AppLauncherDemand()
        for widget in widgets {
            guard case .appLauncher(let settings) = widget.settings else { continue }
            demand.isShown = true
            demand.pinned.formUnion(settings.apps.map(\.key))
            demand.listsRunning = demand.listsRunning || settings.showsRunningApps
        }
        return demand
    }
}
