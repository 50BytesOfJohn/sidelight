import AppKit

extension NSWindow.CollectionBehavior {
    /// Sidelight's panels: on every Space but full-screen ones, where a video or app gets the whole display, and out
    /// of ⌘-Tab. Without `.fullScreenNone`, an accessory app's window that joins every Space shows over full-screen
    /// apps too.
    ///
    /// A window keeps the Spaces it was first shown on: changing its behaviour later doesn't reliably move it onto a
    /// full-screen Space or off one again. So a quick look over a full-screen app is a window of its own, with
    /// ``overFullScreen``, rather than the panel's window changing its behaviour.
    static let panel: Self = [.canJoinAllSpaces, .stationary, .fullScreenNone, .ignoresCycle]

    /// Only on the full-screen Space showing when the window is first shown, over the app there, out of ⌘-Tab.
    static let overFullScreen: Self = [.fullScreenAuxiliary, .ignoresCycle]
}
