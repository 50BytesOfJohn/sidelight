import AppKit

extension NSApplication {
    /// Brings the app to the front even when no other app yields activation.
    ///
    /// macOS 14's cooperative activation makes plain `activate()` a no-op when, for example, the app was
    /// launched in the background. The deprecated `activate(ignoringOtherApps:)` still forces it (verified on
    /// macOS 27). Calling it through ``LegacyActivating`` keeps the deprecation warning out of the build; switch to
    /// `activate()` once that reliably brings windows of an accessory app to the front.
    func activateForcingForeground() {
        (self as any LegacyActivating).activate(ignoringOtherApps: true)
    }
}

private protocol LegacyActivating {
    func activate(ignoringOtherApps flag: Bool)
}

extension NSApplication: LegacyActivating {}
