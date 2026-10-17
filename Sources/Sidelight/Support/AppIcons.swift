import AppKit
import SidelightCore

/// Apps' icons and names, looked up once each, as rows and grids redraw often. Shared by the Stash widget, which
/// knows apps by bundle identifier, and the App Launcher, which knows them by path. It holds a few dozen apps: those
/// pinned or stashed from. The launcher's details panel, which lists every app, keeps its own icons.
enum AppIcons {
    private static var byBundleID: [String: (icon: NSImage, name: String)?] = [:]
    private static var byPath: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage? { app(bundleID)?.icon }

    static func name(for bundleID: String) -> String? { app(bundleID)?.name }

    /// The icon of the app at `path`; the generic app icon if there's nothing there.
    static func icon(atPath path: String) -> NSImage {
        if let icon = byPath[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        byPath[path] = icon
        return icon
    }

    /// Forgets the icon of the app at `path`, as it may have changed: apps relaunch after updating.
    static func invalidate(path: String) {
        byPath[path] = nil
    }

    private static func app(_ bundleID: String) -> (icon: NSImage, name: String)? {
        if let cached = byBundleID[bundleID] { return cached }
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { url in
            let path = url.path(percentEncoded: false)
            return (icon: icon(atPath: path), name: AppCatalog.displayName(of: path))
        }
        byBundleID[bundleID] = app
        return app
    }
}
