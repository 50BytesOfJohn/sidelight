import AppKit
import Observation
import SidelightCore

/// Each screen's current desktop picture.
///
/// macOS has no documented notification for wallpaper changes, so this refreshes on cheap signals instead of
/// polling: a Space switch (each Space can have its own picture), a screen change, and a write to the system's
/// wallpaper store, which System Settings saves whenever the picture changes.
@Observable
final class DesktopPictures {
    private(set) var urls: [Display.ID: URL] = [:]

    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var storeWatcher: FileWatcher?
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?

    /// Long enough for the store to be fully written and the new picture applied.
    static let refreshDelay: Duration = .milliseconds(500)

    static var wallpaperStoreURL: URL {
        URL.applicationSupportDirectory.appending(
            path: "com.apple.wallpaper/Store/Index.plist", directoryHint: .notDirectory)
    }

    init() {
        refresh()
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        storeWatcher = FileWatcher(file: Self.wallpaperStoreURL, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
    }

    /// The picture on the display with `id`, or on the main display for `nil`.
    func url(for id: Display.ID?) -> URL? {
        if let id, let url = urls[id] { return url }
        return NSScreen.primary.flatMap { Display($0, isMain: true) }.flatMap { urls[$0.id] }
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            do { try await Task.sleep(for: Self.refreshDelay) } catch { return }
            self?.refresh()
        }
    }

    private func refresh() {
        var current: [Display.ID: URL] = [:]
        for screen in NSScreen.screens {
            if let display = Display(screen, isMain: false), let url = NSWorkspace.shared.desktopImageURL(for: screen) {
                current[display.id] = url
            }
        }
        // Only a real change re-renders the backgrounds that read this.
        if current != urls { urls = current }
    }
}

extension ImageBackground {
    /// The chosen image, or the desktop picture of the display with `displayID` (the main display for `nil`).
    func url(desktopPictures: DesktopPictures, displayID: Display.ID? = nil) -> URL? {
        path.map { URL(filePath: $0) } ?? desktopPictures.url(for: displayID)
    }
}
