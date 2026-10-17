import CoreGraphics
import Foundation
import Testing

@testable import SidelightCore

private func app(_ name: String, _ bundleID: String? = nil, path: String? = nil) -> LauncherApp {
    LauncherApp(path: path ?? "/Applications/\(name).app", bundleID: bundleID, name: name)
}

private func running(
    _ pid: Int32, _ name: String, _ bundleID: String? = nil, path: String? = nil, isRegular: Bool = true
) -> RunningAppInfo {
    RunningAppInfo(
        id: pid, bundleID: bundleID, path: path ?? "/Applications/\(name).app", name: name, isRegular: isRegular)
}

struct AppLauncherSettingsTests {
    private func decode(_ json: String) throws -> AppLauncherSettings {
        try JSONDecoder().decode(AppLauncherSettings.self, from: Data(json.utf8))
    }

    @Test func `an empty object is the defaults`() throws {
        #expect(try decode("{}") == AppLauncherSettings())
    }

    @Test func `hand-edited numbers move into range, and an unknown spacing is regular`() throws {
        let settings = try decode(
            #"{"iconSize": 999, "columns": -3, "rows": 99, "barCount": 0, "spacing": "huge", "showsNames": "yes"}"#)
        #expect(settings.iconSize == 64)
        #expect(settings.columns == 0)
        #expect(settings.rows == 12)
        #expect(settings.barCount == 1)
        #expect(settings.spacing == .regular)
        #expect(settings.showsNames == false)
    }

    @Test func `an app that can't be read is dropped, and so is one pinned twice`() throws {
        let settings = try decode(
            """
            {"apps": [
                {"id": "00000000-0000-4000-8000-000000000001", "path": "/Applications/Safari.app",
                 "bundleID": "com.apple.Safari", "name": "Safari"},
                {"id": "00000000-0000-4000-8000-000000000002", "path": "/Applications/Broken.app"},
                {"id": "00000000-0000-4000-8000-000000000003", "path": "/Applications/Tool.app/", "bundleID": 7,
                 "name": "Tool"},
                {"id": "00000000-0000-4000-8000-000000000004", "path": "/Applications/Safari.app",
                 "bundleID": "com.apple.Safari", "name": "Safari again"}
            ]}
            """)
        #expect(settings.apps.map(\.name) == ["Safari", "Tool"])
        #expect(settings.apps[1].path == "/Applications/Tool.app")
        #expect(settings.apps[1].bundleID == nil)
    }

    @Test func `round trips`() throws {
        let settings = AppLauncherSettings(
            apps: [app("Safari", "com.apple.Safari"), app("Tool")], iconSize: 40, spacing: .roomy, columns: 5,
            rows: 2, barCount: 6, showsNames: true, showsRunningIndicator: false, showsRunningApps: true,
            showsAllAppsTile: false)
        let decoded = try JSONDecoder().decode(AppLauncherSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test func `adding skips apps pinned at the same path`() {
        var settings = AppLauncherSettings(apps: [app("Safari", "com.apple.Safari")])
        let added = settings.add([app("Safari", "com.apple.Safari"), app("Notes", "com.apple.Notes")])
        #expect(added == 1)
        #expect(settings.apps.map(\.name) == ["Safari", "Notes"])
        // The same app twice in one drop is added once.
        #expect(settings.add([app("Mail"), app("Mail")]) == 1)
        #expect(settings.apps.map(\.name) == ["Safari", "Notes", "Mail"])
    }

    @Test func `adding skips a moved app found by its bundle identifier, not another copy`() {
        var settings = AppLauncherSettings(apps: [app("Xcode", "com.apple.dt.Xcode")])
        let beta = app("Xcode-beta", "com.apple.dt.Xcode")
        // The pinned copy is still there: the beta is another app.
        #expect(settings.add([beta], pathExists: { _ in true }) == 1)
        var moved = AppLauncherSettings(apps: [app("Xcode", "com.apple.dt.Xcode")])
        #expect(moved.add([beta], pathExists: { _ in false }) == 0)
    }

    @Test func `adding inserts at an index`() {
        var settings = AppLauncherSettings(apps: [app("A"), app("B"), app("C")])
        settings.add([app("X"), app("Y")], at: 1)
        #expect(settings.apps.map(\.name) == ["A", "X", "Y", "B", "C"])
        settings.add([app("Z")], at: 99)
        #expect(settings.apps.last?.name == "Z")
    }

    @Test func `moving and removing`() {
        var settings = AppLauncherSettings(apps: [app("A"), app("B"), app("C"), app("D")])
        settings.move(fromOffsets: [0], toOffset: 3)
        #expect(settings.apps.map(\.name) == ["B", "C", "A", "D"])
        settings.move(fromOffsets: [3], toOffset: 0)
        #expect(settings.apps.map(\.name) == ["D", "B", "C", "A"])
        settings.remove(settings.apps[1].id)
        #expect(settings.apps.map(\.name) == ["D", "C", "A"])
    }

    @Test func `the sample has fixed ids`() {
        #expect(AppLauncherSettings.sample.apps.count == 8)
        #expect(Set(AppLauncherSettings.sample.apps.map(\.id)).count == 8)
        #expect(AppLauncherSettings.sample == AppLauncherSettings.sample)
    }
}

struct RunningAppsTests {
    @Test func `matches by path, and by bundle identifier only once the path is gone`() {
        let pinned = app("Tool", "com.example.tool")
        let moved = running(1, "Tool", "com.example.tool", path: "/Users/me/Apps/Tool.app")
        let apps = RunningApps(apps: [moved])
        #expect(!apps.isRunning(pinned, pathExists: true))
        #expect(apps.isRunning(pinned, pathExists: false))
        #expect(apps.instances(of: pinned, pathExists: false).map(\.id) == [1])
    }

    @Test func `two copies with one identifier stay apart`() {
        let xcode = app("Xcode", "com.apple.dt.Xcode")
        let beta = app("Xcode-beta", "com.apple.dt.Xcode")
        let apps = RunningApps(apps: [running(2, "Xcode-beta", "com.apple.dt.Xcode")])
        #expect(!apps.isRunning(xcode, pathExists: true))
        #expect(apps.isRunning(beta, pathExists: true))
    }

    @Test func `an app without an identifier matches by path, and a pinned menu-bar app counts`() {
        let tool = app("Tool")
        let bar = app("Rectangle", "com.knollsoft.Rectangle")
        let apps = RunningApps(apps: [
            running(3, "Tool"), running(4, "Rectangle", "com.knollsoft.Rectangle", isRegular: false),
        ])
        #expect(apps.isRunning(tool, pathExists: true))
        #expect(apps.isRunning(bar, pathExists: true))
        let filtered = apps.filtered(for: AppLauncherDemand(isShown: true, pinned: [bar.key]))
        #expect(filtered.apps.map(\.id) == [3, 4])
    }

    @Test func `unpinned lists Dock apps only, in launch order, without Sidelight`() {
        let apps = RunningApps(apps: [
            running(1, "Safari", "com.apple.Safari"), running(2, "Helper", "com.example.helper", isRegular: false),
            running(3, "Sidelight", "app.getsidelight.Sidelight"), running(4, "Zed", "dev.zed.Zed"),
            running(5, "Notes", "com.apple.Notes"),
        ])
        let unpinned = apps.unpinned(
            excluding: [app("Safari", "com.apple.Safari")], ownBundleID: "app.getsidelight.Sidelight")
        #expect(unpinned.map(\.name) == ["Zed", "Notes"])
    }

    @Test func `filtering drops unpinned menu-bar apps, so they never change what's shown`() {
        let demand = AppLauncherDemand(isShown: true, pinned: [app("Safari", "com.apple.Safari").key])
        let before = RunningApps(apps: [running(1, "Safari", "com.apple.Safari")])
        var after = before
        after.apps.append(running(9, "Menu", "com.example.menu", isRegular: false))
        #expect(before.filtered(for: demand) == after.filtered(for: demand))
        after.apps.append(running(10, "Zed", "dev.zed.Zed"))
        #expect(before.filtered(for: demand) != after.filtered(for: demand))
    }
}

struct LauncherGridTests {
    private func grid(
        width: Double = 244, icon: Double = 32, spacing: Double = 8, columns: Int = 0, rows: Int = 0,
        pinned: Int, extra: Int = 0, tile: Bool = true, label: Double = 0
    ) -> LauncherGrid {
        LauncherGrid(
            LauncherGrid.Input(
                width: width, iconSize: icon, spacing: spacing, fixedColumns: columns, rowLimit: rows,
                pinnedCount: pinned, extraCount: extra, showsAllAppsTile: tile, labelHeight: label))
    }

    @Test(arguments: [56.0, 64, 148, 176, 244, 320, 392], [24.0, 32, 40, 56])
    func `fits as many columns as the width allows, and never clips`(width: Double, icon: Double) {
        for spacing in [4.0, 8, 12] {
            let auto = grid(width: width, icon: icon, spacing: spacing, pinned: 30)
            #expect(auto.columns >= 1)
            #expect(auto.width <= width + 0.001)
            #expect(Double(auto.columns + 1) * icon + Double(auto.columns) * spacing > width)
            let fixed = grid(width: width, icon: icon, spacing: spacing, columns: 12, pinned: 30)
            #expect(fixed.columns == min(12, auto.columns))
            #expect(fixed.width <= width + 0.001)
        }
    }

    @Test func `fixed columns that fit are kept, and centred`() {
        let grid = grid(columns: 3, pinned: 5)
        #expect(grid.columns == 3)
        #expect(grid.cellSize == 32)
        #expect(grid.width == 3 * 32 + 2 * 8)
        #expect(grid.rows == [[.pinned(0), .pinned(1), .pinned(2)], [.pinned(3), .pinned(4), .tile]])
    }

    @Test func `the row limit turns the last cell into +N`() {
        let grid = grid(rows: 1, pinned: 10)
        #expect(grid.columns == 6)
        #expect(grid.visibleItems == 5)
        #expect(grid.overflow == 5)
        #expect(grid.showsTile)
        #expect(grid.rows == [[.pinned(0), .pinned(1), .pinned(2), .pinned(3), .pinned(4), .tile]])
    }

    @Test func `the tile never sits alone on a row it only needs for the overflow`() {
        let full = grid(rows: 1, pinned: 6)
        #expect(full.rows.count == 1)
        #expect(full.visibleItems == 5 && full.overflow == 1)
        // Without a limit it may take a row of its own: nothing's hidden.
        let open = grid(pinned: 6)
        #expect(open.rows.count == 2 && open.rows[1] == [.tile])
        #expect(open.overflow == 0)
    }

    @Test func `without the tile, apps fill every cell, and +N shows only for overflow`() {
        let fits = grid(rows: 1, pinned: 6, tile: false)
        #expect(!fits.showsTile && fits.visibleItems == 6)
        let over = grid(rows: 1, pinned: 7, tile: false)
        #expect(over.showsTile && over.visibleItems == 5 && over.overflow == 2)
    }

    @Test func `running apps start a row after a divider, and are hidden first`() {
        let grid = grid(pinned: 4, extra: 3)
        #expect(
            grid.rows == [[.pinned(0), .pinned(1), .pinned(2), .pinned(3)], [.extra(0), .extra(1), .extra(2), .tile]])
        #expect(grid.dividerBeforeRow == 1)
        let limited = self.grid(rows: 1, pinned: 4, extra: 3)
        #expect(limited.visiblePinned == 4 && limited.visibleExtra == 0 && limited.overflow == 3)
        #expect(limited.dividerBeforeRow == nil)
        #expect(limited.rows == [[.pinned(0), .pinned(1), .pinned(2), .pinned(3), .tile]])
        // Only running apps: no divider above them.
        #expect(self.grid(pinned: 0, extra: 2).dividerBeforeRow == nil)
    }

    @Test func `a single column and a single row`() {
        let column = LauncherGrid.column(count: 5, rowLimit: 3, showsAllAppsTile: true)
        #expect(column.rows == [[.pinned(0)], [.pinned(1)], [.tile]])
        #expect(column.overflow == 3)
        #expect(LauncherGrid.column(count: 3, rowLimit: 3, showsAllAppsTile: false).rows.count == 3)
        #expect(LauncherGrid.column(count: 0, rowLimit: 0, showsAllAppsTile: true).rows == [[.tile]])

        let bar = LauncherGrid.bar(count: 10, limit: 8, showsAllAppsTile: false)
        #expect(bar.rows.count == 1 && bar.rows[0].count == 9)
        #expect(bar.rows[0].last == .tile && bar.overflow == 2)
        let short = LauncherGrid.bar(count: 3, limit: 8, showsAllAppsTile: true)
        #expect(short.rows == [[.pinned(0), .pinned(1), .pinned(2), .tile]] && short.overflow == 0)
        #expect(LauncherGrid.bar(count: 0, limit: 8, showsAllAppsTile: false).rows.isEmpty)
    }

    @Test func `drops insert at the nearest gap`() {
        // 6 columns of 34 pt with 8 pt gaps; rows 38 pt tall.
        let grid = grid(pinned: 8)
        #expect(grid.cellSize == 34)
        #expect(grid.rowHeight == 38)
        #expect(grid.insertionIndex(at: CGPoint(x: 5, y: 10)) == 0)
        #expect(grid.insertionIndex(at: CGPoint(x: 30, y: 10)) == 1)
        #expect(grid.insertionIndex(at: CGPoint(x: 1000, y: 10)) == 6)
        #expect(grid.insertionIndex(at: CGPoint(x: 30, y: 51)) == 7)
        #expect(grid.insertionIndex(at: CGPoint(x: 200, y: 51)) == 8)
        #expect(grid.insertionIndex(at: CGPoint(x: 30, y: 400)) == 8)
        #expect(grid.insertionIndex(at: CGPoint(x: -40, y: -5)) == 0)
        #expect(self.grid(pinned: 0).insertionIndex(at: CGPoint(x: 30, y: 10)) == 0)
    }
}

struct AppCatalogTests {
    private func makeApp(_ url: URL, bundleID: String?) throws {
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundlePackageType": "APPL"]
        if let bundleID { info["CFBundleIdentifier"] = bundleID }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
    }

    @Test func `finds apps two levels deep, never inside one, nor hidden`() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appending(path: "Applications")
        try makeApp(apps.appending(path: "App 10.app"), bundleID: "com.example.ten")
        try makeApp(apps.appending(path: "App 2.app"), bundleID: "com.example.two")
        try makeApp(apps.appending(path: "Utilities/Tool.app"), bundleID: nil)
        try makeApp(apps.appending(path: "Utilities/Deeper/Lost.app"), bundleID: "com.example.lost")
        try makeApp(apps.appending(path: "App 2.app/Contents/Helpers/Inner.app"), bundleID: "com.example.inner")
        try makeApp(apps.appending(path: ".Hidden.app"), bundleID: "com.example.hidden")
        let link = root.appending(path: "Linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: apps)

        let found = await AppCatalog.scan([
            (apps, .applications), (link, .user), (root.appending(path: "Missing"), .system),
        ])
        #expect(found.map(\.name) == ["App 2", "App 10", "Tool"])
        #expect(found.map(\.bundleID) == ["com.example.two", "com.example.ten", nil])
        #expect(found.allSatisfy { $0.folder == .applications })
    }

    @Test func `a link to an app is listed where it leads, once`() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appending(path: "Real/Safari.app")
        try makeApp(real, bundleID: "com.apple.Safari")
        let apps = root.appending(path: "Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: apps.appending(path: "Safari.app"), withDestinationURL: real)

        let found = await AppCatalog.scan([(apps, .applications), (root.appending(path: "Real"), .system)])
        #expect(found.count == 1)
        #expect(
            found.first?.path == LauncherApp.standardize(real.resolvingSymlinksInPath().path(percentEncoded: false)))
    }

    @Test func `running apps found in no folder are added as elsewhere`() {
        let scanned = [
            CatalogApp(path: "/Applications/Zed.app", bundleID: "dev.zed.Zed", name: "Zed", folder: .applications)
        ]
        let merged = AppCatalog.merging(
            scanned,
            running: [
                running(1, "Zed", "dev.zed.Zed"),
                running(2, "MyApp", "com.me.app", path: "/Users/me/DerivedData/MyApp.app"),
                running(3, "Helper", "com.me.helper", path: "/Users/me/Helper.app", isRegular: false),
            ])
        #expect(merged.map(\.name) == ["MyApp", "Zed"])
        #expect(merged.first?.folder == .elsewhere)
    }
}

struct AppSearchTests {
    let apps = [
        CatalogApp(path: "/A/Xcode.app", bundleID: "com.apple.dt.Xcode", name: "Xcode", folder: .applications),
        CatalogApp(
            path: "/A/VS.app", bundleID: "com.microsoft.VSCode", name: "Visual Studio Code", folder: .applications),
        CatalogApp(path: "/A/Codex.app", bundleID: "com.openai.codex", name: "Codex", folder: .applications),
        CatalogApp(path: "/A/Cafe.app", bundleID: "com.example.cafe", name: "Café", folder: .applications),
        CatalogApp(path: "/A/Notes.app", bundleID: "com.apple.Notes", name: "Notes", folder: .applications),
    ]

    @Test func `name prefix, then word prefix, then anywhere in the name`() {
        #expect(AppSearch("CODE").ranked(apps).map(\.name) == ["Codex", "Visual Studio Code", "Xcode"])
    }

    @Test func `ignores accents, and matches bundle identifiers last`() {
        #expect(AppSearch("cafe").ranked(apps).map(\.name) == ["Café"])
        #expect(AppSearch("microsoft").ranked(apps).map(\.name) == ["Visual Studio Code"])
        #expect(AppSearch("apple").ranked(apps).map(\.name) == ["Xcode", "Notes"])
    }

    @Test func `an empty search lists everything`() {
        #expect(AppSearch("  ").ranked(apps) == apps)
        #expect(AppSearch("zzz").ranked(apps).isEmpty)
    }
}

struct NewWindowMenuTests {
    private func item(
        _ title: String, _ key: String?, _ path: [Int], modifiers: Int = 0, enabled: Bool = true
    ) -> MenuItemInfo {
        MenuItemInfo(title: title, commandKey: key, modifiers: modifiers, isEnabled: enabled, path: path)
    }

    @Test func `Finder`() {
        let items = [
            item("About Finder", nil, [0, 0]), item("New Finder Window", "N", [2, 0]),
            item("New Folder", "N", [2, 1], modifiers: 1), item("New Tab", "T", [2, 2]),
        ]
        #expect(NewWindowMenu.best(in: items)?.title == "New Finder Window")
    }

    @Test func `Chrome and Safari`() {
        let chrome = [
            item("New Tab", "T", [2, 0]), item("New Window", "N", [2, 1]),
            item("New Incognito Window", "N", [2, 2], modifiers: 1),
        ]
        #expect(NewWindowMenu.best(in: chrome)?.path == [2, 1])
        let safari = [
            item("New Window", "N", [2, 0]), item("New Private Window", "N", [2, 1], modifiers: 1),
            item("New Tab", "T", [2, 2]),
        ]
        #expect(NewWindowMenu.best(in: safari)?.path == [2, 0])
    }

    @Test func `Zed's New Window is on shift`() {
        let items = [item("New", "N", [2, 0]), item("New Window", "N", [2, 1], modifiers: 1)]
        #expect(NewWindowMenu.best(in: items)?.title == "New Window")
    }

    @Test func `kitty's New Window is a split`() {
        let items = [
            item("New OS Window", "N", [3, 0]), item("New Window", "\r", [3, 1]), item("New Tab", "T", [3, 2]),
        ]
        #expect(NewWindowMenu.best(in: items)?.title == "New OS Window")
    }

    @Test func `Terminal's New Window is a submenu, so its Command-N profile is pressed`() {
        let items = [item("New Window", nil, [2, 0]), item("Basic", "N", [2, 0, 0]), item("New Tab", "T", [2, 1])]
        #expect(NewWindowMenu.best(in: items)?.path == [2, 0, 0])
    }

    @Test func `disabled items, the Apple menu, and nothing to press`() {
        let items = [
            item("Secret", "N", [0, 3]), item("New Window", "N", [2, 0], enabled: false),
            item("New Document", "N", [2, 1]),
        ]
        #expect(NewWindowMenu.best(in: items)?.title == "New Document")
        #expect(NewWindowMenu.best(in: [item("Open…", "O", [2, 0])]) == nil)
        #expect(NewWindowMenu.best(in: []) == nil)
    }
}

struct AppLauncherDemandTests {
    static func configuration(_ widgets: [WidgetInstance]) -> AppConfiguration {
        var configuration = AppConfiguration()
        configuration.sections = [PanelSection(widgets: widgets)]
        return configuration
    }

    @Test func `a visible launcher is shown with its apps, a hidden one is nothing`() {
        let safari = app("Safari", "com.apple.Safari")
        let shown = WidgetInstance(settings: .appLauncher(AppLauncherSettings(apps: [safari], showsRunningApps: true)))
        let hidden = WidgetInstance(
            settings: .appLauncher(AppLauncherSettings(apps: [app("Notes")])), showsInSidePanel: false,
            showsInBar: false)
        let demand = Self.configuration([shown, hidden]).serviceDemand(at: [.right]).appLauncher
        #expect(demand.isShown)
        #expect(demand.pinned == [safari.key])
        #expect(demand.listsRunning)
        #expect(Self.configuration([hidden]).serviceDemand(at: [.right]).appLauncher.isEmpty)
    }

    @Test func `previewing every widget shows it`() {
        let configuration = Self.configuration([WidgetInstance(kind: .clock)])
        #expect(!configuration.serviceDemand(at: [.right], previewsEveryWidget: true).appLauncher.isEmpty)
    }

    @Test func `limiting to other kinds drops it, and merging adds up`() {
        let demand = Self.configuration([WidgetInstance(kind: .appLauncher)]).serviceDemand(at: [.right])
        #expect(!demand.appLauncher.isEmpty)
        #expect(demand.limited(to: [.clock]).appLauncher.isEmpty)
        #expect(!demand.limited(to: [.appLauncher]).appLauncher.isEmpty)

        var merged = AppLauncherDemand()
        merged.merge(AppLauncherDemand(isShown: true, pinned: [app("A").key], listsRunning: true))
        merged.merge(AppLauncherDemand(isShown: false, pinned: [app("B").key]))
        #expect(merged.isShown && merged.listsRunning && merged.pinned.count == 2)
    }

    @Test func `editing a launcher in place`() {
        let widget = WidgetInstance(kind: .appLauncher)
        var configuration = Self.configuration([widget, WidgetInstance(kind: .clock)])
        configuration.updateAppLauncher(widget.id) { $0.add([app("Safari")]) }
        guard case .appLauncher(let settings) = configuration.widget(widget.id)?.settings else {
            Issue.record("Not a launcher")
            return
        }
        #expect(settings.apps.map(\.name) == ["Safari"])
    }
}
