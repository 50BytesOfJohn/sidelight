import Foundation

/// Where an app in the catalog was found.
public enum CatalogFolder: String, Hashable, Sendable {
    /// `/Applications`.
    case applications
    /// `/System/Applications`, and the system's apps elsewhere.
    case system
    /// `~/Applications`.
    case user
    /// `/System/Library/CoreServices/Applications`.
    case coreServices
    /// None of them: only known because it's running, such as a build of one's own app.
    case elsewhere
}

/// One app the details panel can list.
public struct CatalogApp: Hashable, Sendable, Identifiable {
    public var id: String { path }
    /// Standardized, with symbolic links resolved.
    public var path: String
    public var bundleID: String?
    public var name: String
    public var folder: CatalogFolder

    public init(path: String, bundleID: String?, name: String, folder: CatalogFolder) {
        self.path = path
        self.bundleID = bundleID
        self.name = name
        self.folder = folder
    }
}

/// Every app installed in the usual places, for the details panel. Read once each time it opens, off the main actor:
/// a shallow look through a few folders, not a Spotlight query kept running.
public enum AppCatalog {
    /// `/Applications`, `/System/Applications`, `~/Applications` and `/System/Library/CoreServices/Applications`.
    /// Their `Utilities` folders are found as subfolders.
    public static func defaultRoots(home: URL) -> [(url: URL, folder: CatalogFolder)] {
        [
            (URL(filePath: "/Applications", directoryHint: .isDirectory), .applications),
            (URL(filePath: "/System/Applications", directoryHint: .isDirectory), .system),
            (home.appending(path: "Applications", directoryHint: .isDirectory), .user),
            (URL(filePath: "/System/Library/CoreServices/Applications", directoryHint: .isDirectory), .coreServices),
        ]
    }

    /// The apps in `roots` and their subfolders (two levels deep), never looking inside an app or at hidden files.
    /// Each app is listed once, under the path its symbolic links lead to, sorted by name as Finder sorts.
    @concurrent
    public static func scan(_ roots: [(url: URL, folder: CatalogFolder)]) async -> [CatalogApp] {
        let fileManager = FileManager()
        var seen = Set<String>()
        var apps: [CatalogApp] = []
        func visit(_ directory: URL, folder: CatalogFolder, depth: Int) {
            guard !Task.isCancelled,
                let entries = try? fileManager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { return }
            for entry in entries {
                if entry.pathExtension.lowercased() == "app" {
                    let resolved = entry.resolvingSymlinksInPath()
                    let path = LauncherApp.standardize(resolved.path(percentEncoded: false))
                    guard seen.insert(path).inserted, fileManager.fileExists(atPath: path) else { continue }
                    apps.append(app(at: resolved, path: path, folder: folder, fileManager: fileManager))
                } else if depth < 2,
                    let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                    values.isDirectory == true, values.isPackage != true
                {
                    visit(entry, folder: folder, depth: depth + 1)
                }
            }
        }
        var roots = roots
        // A root that's a link to another (or the same folder twice) is looked through once.
        var rootPaths = Set<String>()
        roots.removeAll { !rootPaths.insert($0.url.resolvingSymlinksInPath().path(percentEncoded: false)).inserted }
        for root in roots { visit(root.url, folder: root.folder, depth: 1) }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Adds the running apps found in no folder (a build in DerivedData, an app in Downloads) as `.elsewhere`.
    public static func merging(_ scanned: [CatalogApp], running: [RunningAppInfo]) -> [CatalogApp] {
        var paths = Set(scanned.map(\.path))
        var apps = scanned
        for info in running where info.isRegular {
            guard let path = info.path, path.hasSuffix(".app"), paths.insert(path).inserted else { continue }
            apps.append(CatalogApp(path: path, bundleID: info.bundleID, name: info.name, folder: .elsewhere))
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The app at `url`, wherever its symbolic links lead.
    public static func app(at url: URL, folder: CatalogFolder = .elsewhere) -> CatalogApp {
        let resolved = url.resolvingSymlinksInPath()
        let path = LauncherApp.standardize(resolved.path(percentEncoded: false))
        return app(at: resolved, path: path, folder: folder, fileManager: .default)
    }

    /// The app at `url`: its identifier from its `Info.plist`, read directly rather than through `Bundle`, which
    /// keeps every bundle it opens for good.
    static func app(at url: URL, path: String, folder: CatalogFolder, fileManager: FileManager) -> CatalogApp {
        let plist = url.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        let info =
            (try? Data(contentsOf: plist))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let bundleID = (info?["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CatalogApp(
            path: path, bundleID: bundleID, name: displayName(of: path, fileManager: fileManager),
            folder: folder)
    }

    /// The app's name as Finder shows it, without `.app`.
    public static func displayName(of path: String, fileManager: FileManager = .default) -> String {
        let name = fileManager.displayName(atPath: path)
        return name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

/// What someone typed in the details panel's search, and the apps that match it, best first.
public struct AppSearch: Sendable {
    public let text: String
    private let folded: String

    public init(_ text: String) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        folded = Self.fold(self.text)
    }

    public var isEmpty: Bool { folded.isEmpty }

    /// The apps that match, ignoring case and accents: names starting with the text, then names with a word starting
    /// with it ("code" finds Visual Studio Code), then names containing it, then bundle identifiers containing it
    /// ("microsoft" finds it too). Each group keeps the order it was given. Every app, when the search is empty.
    public func ranked(_ apps: [CatalogApp]) -> [CatalogApp] {
        guard !isEmpty else { return apps }
        var groups: [[CatalogApp]] = [[], [], [], []]
        for app in apps {
            if let rank = rank(app) { groups[rank].append(app) }
        }
        return groups.flatMap(\.self)
    }

    /// Whether `app` matches at all.
    public func matches(_ app: CatalogApp) -> Bool {
        isEmpty || rank(app) != nil
    }

    private func rank(_ app: CatalogApp) -> Int? {
        let name = Self.fold(app.name)
        if name.hasPrefix(folded) { return 0 }
        let words = name.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(folded) }) { return 1 }
        if name.contains(folded) { return 2 }
        if let bundleID = app.bundleID, Self.fold(bundleID).contains(folded) { return 3 }
        return nil
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
