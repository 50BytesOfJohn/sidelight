import AppKit

/// Whether anything of a window can be seen: AppKit's occlusion state for it, combined with the screens sleeping and
/// the session being switched away from or locked, which AppKit doesn't promise to report as occlusion.
///
/// Each of Sidelight's own surfaces (a display's panel, the details panel) watches its own window, so one being
/// ordered out on purpose never makes another look unseen.
final class WindowVisibility {
    /// Nothing of the window can be seen right now.
    private(set) var isOccluded = false

    private weak var window: NSWindow?
    /// Told when ``isOccluded`` changes.
    private let onChange: (_ isOccluded: Bool) -> Void
    private var occlusionObserver: (any NSObjectProtocol)?
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var areScreensAsleep = false
    private var isSessionInactive = false

    init(of window: NSWindow, onChange: @escaping (_ isOccluded: Bool) -> Void) {
        self.onChange = onChange
        observeOcclusion(of: window)
        workspaceObservers = [
            NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        .map { name in
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.workspaceChanged(name) }
            }
        }
    }

    /// Watches `window` instead, as when a panel's content moves to a window of its own for a quick look over a
    /// full-screen app, and tells at once whether anything of it can be seen.
    func watch(_ window: NSWindow) {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        observeOcclusion(of: window)
        update()
    }

    private func observeOcclusion(of window: NSWindow) {
        self.window = window
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    /// Stops watching. Safe to call more than once.
    func invalidate() {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers = []
    }

    private func workspaceChanged(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.screensDidSleepNotification: areScreensAsleep = true
        case NSWorkspace.screensDidWakeNotification: areScreensAsleep = false
        case NSWorkspace.sessionDidResignActiveNotification: isSessionInactive = true
        case NSWorkspace.sessionDidBecomeActiveNotification: isSessionInactive = false
        default: return
        }
        update()
    }

    /// Combines all the signals, so waking the screens still counts as occluded while the lock screen covers them.
    private func update() {
        let isWindowVisible = window?.occlusionState.contains(.visible) ?? false
        let isOccluded = areScreensAsleep || isSessionInactive || !isWindowVisible
        guard isOccluded != self.isOccluded else { return }
        self.isOccluded = isOccluded
        onChange(isOccluded)
    }
}
