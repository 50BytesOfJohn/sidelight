import AppKit
import SidelightCore
import os

/// Everything that touches another app, in one place: views never call `NSWorkspace` for the launcher themselves.
enum AppLauncherActions {
    /// Opens the app at `url`, or brings it forward if it's running, as a Dock click does: through Launch Services,
    /// which also asks an app with no windows open to open one. Sidelight is never the active app, so it can't hand
    /// activation over with `NSRunningApplication.activate`. A second click while it launches does nothing.
    static func open(_ url: URL, id: LauncherApp.ID?, service: AppLauncherService) {
        if let id, !service.beginLaunching(id) { return }
        Task {
            defer { if let id { service.finishLaunching(id) } }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            } catch {
                NSSound.beep()
                Log.appLauncher.notice("Couldn't open an app: \(error.localizedDescription, privacy: .public)")
                Log.appLauncher.debug("It was \(url.path(percentEncoded: false), privacy: .private)")
            }
        }
    }

    /// Shows the app in Finder.
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func hide(_ instances: [RunningAppInfo]) {
        for app in running(instances) { app.hide() }
    }

    static func unhide(_ instances: [RunningAppInfo]) {
        for app in running(instances) { app.unhide() }
    }

    /// Asks every copy to quit, as the Dock's Quit does; each may ask to save first.
    static func quit(_ instances: [RunningAppInfo]) {
        for app in running(instances) { app.terminate() }
    }

    static func forceQuit(_ instances: [RunningAppInfo]) {
        for app in running(instances) { app.forceTerminate() }
    }

    /// Whether any copy is hidden, read now rather than from the last published list.
    static func isHidden(_ instances: [RunningAppInfo]) -> Bool {
        running(instances).contains(where: \.isHidden)
    }

    /// Opens a new window: presses the app's own "new window" menu item through Accessibility (see
    /// ``NewWindowMenu``), then brings the app forward so the window is in front. An app that isn't running, or has
    /// no such item, is just opened, which opens a window if it has none.
    static func newWindow(
        _ instances: [RunningAppInfo], url: URL, id: LauncherApp.ID?, service: AppLauncherService
    ) async {
        if let pid = instances.first?.id {
            let pressed = await pressNewWindow(pid: pid)
            Log.appLauncher.debug("New Window pressed \(pressed ?? "nothing", privacy: .public)")
        }
        open(url, id: id, service: service)
    }

    @concurrent
    nonisolated private static func pressNewWindow(pid: pid_t) async -> String? {
        guard let item = NewWindowMenu.best(in: AccessibilityElement.menuItems(ofProcess: pid)),
            AccessibilityElement.pressMenuItem(ofProcess: pid, at: item.path)
        else { return nil }
        return item.title
    }

    private static func running(_ instances: [RunningAppInfo]) -> [NSRunningApplication] {
        instances.compactMap { NSRunningApplication(processIdentifier: $0.id) }
    }
}
