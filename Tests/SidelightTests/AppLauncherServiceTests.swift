import Foundation
import Testing

@testable import Sidelight
@testable import SidelightCore

/// Running apps and app folders from a script: the test sets what's running and says when it changed.
private final class FakeWorkspace {
    var apps: [RunningAppInfo] = []
    /// Paths with an app, and its bundle identifier.
    var installed: [String: String?] = [:]
    var located: [String: URL] = [:]
    private(set) var observations = 0
    private(set) var cancellations = 0
    private(set) var snapshots = 0
    private var changed: (@Sendable @MainActor () -> Void)?

    var source: AppLauncherService.Source {
        AppLauncherService.Source(
            snapshot: { [unowned self] in
                snapshots += 1
                return apps
            },
            observe: { [unowned self] changed in
                observations += 1
                self.changed = changed
                return AppLauncherService.Subscription { [unowned self] in
                    cancellations += 1
                    self.changed = nil
                }
            },
            inspect: { [unowned self] path in
                guard let bundleID = installed[path] else { return (false, nil) }
                return (true, bundleID)
            },
            locate: { [unowned self] in located[$0] })
    }

    /// What `NSWorkspace` tells the service: something changed. Nothing happens once it stopped observing.
    func change() {
        changed?()
    }
}

private func info(_ pid: Int32, _ name: String, _ bundleID: String?, isRegular: Bool = true) -> RunningAppInfo {
    RunningAppInfo(
        id: pid, bundleID: bundleID, path: "/Applications/\(name).app", name: name, isRegular: isRegular)
}

struct AppLauncherServiceTests {
    private let safari = LauncherApp(path: "/Applications/Not Safari.app", bundleID: "com.apple.Safari", name: "Safari")

    @Test func `starting twice observes once; stopping ends it; starting again reads at once`() {
        let workspace = FakeWorkspace()
        workspace.apps = [info(1, "Safari", "com.apple.Safari")]
        let service = AppLauncherService(source: workspace.source)
        service.demand = AppLauncherDemand(isShown: true)
        service.start()
        service.start()
        #expect(workspace.observations == 1)
        #expect(service.running.apps.map(\.id) == [1])

        service.stop()
        #expect(workspace.cancellations == 1)
        workspace.apps.append(info(2, "Zed", "dev.zed.Zed"))
        workspace.change()
        // Stopped: it keeps what it read.
        #expect(service.running.apps.map(\.id) == [1])
        service.start()
        #expect(service.running.apps.map(\.id) == [1, 2])
    }

    @Test func `an unpinned menu-bar app publishes nothing, a pinned one does`() {
        let workspace = FakeWorkspace()
        let service = AppLauncherService(source: workspace.source)
        let rectangle = LauncherApp(
            path: "/Applications/Rectangle.app", bundleID: "com.knollsoft.Rectangle", name: "Rectangle")
        service.demand = AppLauncherDemand(isShown: true, pinned: [rectangle.key])
        service.start()
        let before = service.running

        workspace.apps.append(info(5, "Helper", "com.example.helper", isRegular: false))
        workspace.change()
        #expect(service.running == before)

        workspace.apps.append(info(6, "Rectangle", "com.knollsoft.Rectangle", isRegular: false))
        workspace.change()
        #expect(service.running.apps.map(\.id) == [6])
    }

    @Test func `an app that becomes a Dock app after launching is listed on the next change`() {
        let workspace = FakeWorkspace()
        let service = AppLauncherService(source: workspace.source)
        service.demand = AppLauncherDemand(isShown: true, listsRunning: true)
        service.start()
        workspace.apps = [info(7, "Probe", "com.example.probe", isRegular: false)]
        workspace.change()
        #expect(service.unpinned(excluding: []).isEmpty)
        workspace.apps = [info(7, "Probe", "com.example.probe")]
        workspace.change()
        #expect(service.unpinned(excluding: []).map(\.name) == ["Probe"])
    }

    @Test func `launching ends when the open finishes, or on the watchdog`() async throws {
        let service = AppLauncherService(source: FakeWorkspace().source, launchWatchdog: .milliseconds(20))
        let id = UUID()
        #expect(service.beginLaunching(id))
        #expect(!service.beginLaunching(id))
        service.finishLaunching(id)
        #expect(service.launching.isEmpty)

        #expect(service.beginLaunching(id))
        #expect(await eventually { service.launching.isEmpty })
    }

    @Test func `finds a moved app by its bundle identifier, and a deleted one is missing`() {
        let workspace = FakeWorkspace()
        let service = AppLauncherService(source: workspace.source)
        service.start()
        workspace.installed[safari.path] = "com.apple.Safari"
        #expect(
            service.resolve(safari) == .found(URL(filePath: safari.path, directoryHint: .isDirectory), pathExists: true)
        )

        let tool = LauncherApp(path: "/Applications/Tool.app", bundleID: "com.example.tool", name: "Tool")
        let moved = URL(filePath: "/Users/me/Apps/Tool.app", directoryHint: .isDirectory)
        workspace.located["com.example.tool"] = moved
        #expect(service.resolve(tool) == .found(moved, pathExists: false))

        let gone = LauncherApp(path: "/Applications/Gone.app", bundleID: "com.example.gone", name: "Gone")
        #expect(service.resolve(gone) == .missing)

        let replaced = LauncherApp(path: "/Applications/Old.app", bundleID: "com.example.old", name: "Old")
        workspace.installed[replaced.path] = "com.example.other"
        #expect(service.resolve(replaced) == .missing)
    }

    @Test func `where apps are is looked up again once the pinned apps change`() {
        let workspace = FakeWorkspace()
        let service = AppLauncherService(source: workspace.source)
        #expect(service.resolve(safari) == .missing)
        workspace.installed[safari.path] = "com.apple.Safari"
        // Cached until something changes.
        #expect(service.resolve(safari) == .missing)
        service.demand = AppLauncherDemand(isShown: true, pinned: [safari.key])
        #expect(service.resolve(safari) != .missing)
    }

    @Test func `a moved pinned app's running copy counts as it`() {
        let workspace = FakeWorkspace()
        let tool = LauncherApp(path: "/Applications/Tool.app", bundleID: "com.example.tool", name: "Tool")
        workspace.located["com.example.tool"] = URL(filePath: "/Users/me/Apps/Tool.app", directoryHint: .isDirectory)
        workspace.apps = [
            RunningAppInfo(
                id: 9, bundleID: "com.example.tool", path: "/Users/me/Apps/Tool.app", name: "Tool", isRegular: true)
        ]
        let service = AppLauncherService(source: workspace.source)
        service.demand = AppLauncherDemand(isShown: true, pinned: [tool.key], listsRunning: true)
        service.start()
        #expect(service.isRunning(tool))
        #expect(service.unpinned(excluding: [tool]).isEmpty)
    }
}
