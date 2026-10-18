import AppKit
import Observation
import SidelightCore
import os

/// Moves and resizes the frontmost window into tiles on a shortcut (see ``WindowAction`` and ``WindowLayout``), always
/// clear of the panel.
///
/// Not a data service: nothing runs between presses. It watches nothing, polls nothing, and while it's off it asks
/// for no access and keeps nothing. What it keeps while on is in memory only: the last press, for cycling a half's
/// size, and where windows were before it first placed them, for putting them back.
@Observable
final class WindowManager {
    /// How many windows ``WindowAction/restore`` can put back, the most recently placed first.
    static let restoreLimit = 32

    @ObservationIgnored private(set) var settings = WindowManagerSettings()
    /// The strips the panels keep clear, which tiles stay out of; empty while the panels are hidden.
    @ObservationIgnored var occupiedRegions: () -> [PanelRegion] = { [] }

    @ObservationIgnored private let permission: AccessibilityPermission
    @ObservationIgnored private let avoider: WindowAvoider
    @ObservationIgnored private var cycle = SizeCycle()
    /// The window the last press placed, which ``cycle`` is about.
    @ObservationIgnored private var lastWindow: ManagedWindow?
    @ObservationIgnored private var restoreList: [RestoreEntry] = []

    private static let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier

    init(permission: AccessibilityPermission, avoider: WindowAvoider) {
        self.permission = permission
        self.avoider = avoider
    }

    /// Takes new settings. Switched on, it needs Accessibility access, and asks for it if `promptingForAccess`;
    /// switched off, it forgets everything.
    func apply(_ settings: WindowManagerSettings, promptingForAccess: Bool = true) {
        let wasEnabled = self.settings.isEnabled
        self.settings = settings
        guard settings.isEnabled != wasEnabled else { return }
        permission.setNeeded(settings.isEnabled, by: .windowManager)
        guard settings.isEnabled else {
            cycle.reset()
            lastWindow = nil
            restoreList = []
            return
        }
        // So a hung app costs a second at most, even with window avoidance off.
        AccessibilityElement.limitMessagingTimeout()
        if promptingForAccess, !permission.isTrusted { permission.check(prompting: true) }
    }

    /// Does `action` to the frontmost window; beeps when it can't.
    func perform(_ action: WindowAction) {
        guard settings.isEnabled, let window = frontWindow() else { return }
        guard let current = window.frame else { return fail(action, "its frame can't be read") }
        let displays = DisplayArea.all(regions: occupiedRegions(), padding: CGFloat(settings.padding))
        guard let source = WindowLayout.sourceDisplay(of: current, among: displays.map(\.frame)) else {
            return fail(action, "no display")
        }
        let isSameWindow = lastWindow?.isSame(as: window) ?? false
        let now = ContinuousClock.now

        switch action {
        case .restore:
            restore(window)
        case .nextDisplay, .previousDisplay:
            guard
                let target = WindowLayout.neighbor(
                    of: source, among: displays.map(\.frame), forward: action == .nextDisplay)
            else { return fail(action, "there's only one display") }
            let area = displays[target]
            // Still the tile the last press left it as: the same tile there. Otherwise in proportion.
            if let placement = cycle.placement(isSameWindow: isSameWindow, frame: current),
                let tile = frame(for: placement.action, step: placement.step, size: current.size, on: area)
            {
                guard let accepted = place(window, at: tile, from: current, as: placement.action, on: area)
                else { return fail(action, "it can't be moved") }
                cycle.record(action, placement: placement, accepted: accepted, now: now)
            } else {
                let moved = WindowLayout.transfer(current, from: displays[source].workArea, to: area.workArea)
                guard let accepted = place(window, at: moved, from: current, as: nil, on: area) else {
                    return fail(action, "it can't be moved")
                }
                cycle.record(action, placement: nil, accepted: accepted, now: now)
            }
        default:
            let step = cycle.step(
                for: action, isSameWindow: isSameWindow, frame: current, now: now, cycles: settings.cyclesSizes)
            let area = displays[source]
            guard let tile = frame(for: action, step: step, size: current.size, on: area) else { return }
            guard let accepted = place(window, at: tile, from: current, as: action, on: area) else {
                return fail(action, "it can't be moved")
            }
            cycle.record(action, placement: (action, step), accepted: accepted, now: now)
            Log.windowManager.debug(
                "\(action.rawValue, privacy: .public) step \(step) to \(NSStringFromRect(accepted), privacy: .public)")
        }
        lastWindow = window
    }

    // MARK: Placing

    /// Where `action` at `step` puts a window of `size` on `display`.
    private func frame(for action: WindowAction, step: Int, size: CGSize, on display: DisplayArea) -> CGRect? {
        if action == .center { return WindowLayout.centered(size, in: display.workArea) }
        return WindowLayout.frame(
            for: action, step: step, in: display.workArea, gap: CGFloat(settings.gap), isPortrait: display.isPortrait)
    }

    /// Puts `window`, now at `current`, at `frame`, as the tile for `action` (`nil` for a move to another display).
    /// A window of a fixed size keeps it, centred where the tile is; one the app sizes differently is moved again to
    /// keep the tile's edges (see ``WindowLayout/anchored(_:for:tile:in:isPortrait:)``). Returns the frame the app accepted, after
    /// noting where to put the window back and telling window avoidance the window is placed on purpose; `nil` when it
    /// can't be moved.
    private func place(
        _ window: ManagedWindow, at frame: CGRect, from current: CGRect, as action: WindowAction?,
        on display: DisplayArea
    ) -> CGRect? {
        let area = display.workArea
        guard window.isPositionSettable else { return nil }
        var requested = frame
        if !window.isSizeSettable {
            let centered = CGRect(
                x: (frame.midX - current.width / 2).rounded(.down), y: (frame.midY - current.height / 2).rounded(.down),
                width: current.width, height: current.height)
            requested = WindowLayout.clamped(centered, to: area)
        }
        noteOriginal(of: window, at: current)
        guard var accepted = window.setFrame(requested) else { return nil }
        if abs(accepted.width - requested.width) > 1 || abs(accepted.height - requested.height) > 1 {
            let anchored =
                action.map {
                    WindowLayout.anchored(
                        accepted.size, for: $0, tile: requested, in: area, isPortrait: display.isPortrait)
                }
                ?? WindowLayout.clamped(accepted, to: area)
            if !ReservationTransition.isUnchanged(anchored, since: accepted) {
                accepted = window.setFrame(anchored) ?? accepted
            }
        }
        if !restoreList.isEmpty { restoreList[0].lastSet = accepted }
        window.placed(by: avoider)
        return accepted
    }

    // MARK: Restoring

    /// A window placed by the manager, where it was before, and where it was last put.
    private struct RestoreEntry {
        let window: ManagedWindow
        let original: CGRect
        var lastSet: CGRect
    }

    /// Notes where `window` is before it's placed, as the newest entry: a window still where the manager last put it
    /// keeps the frame from before the first placement; one moved since starts from where it is.
    private func noteOriginal(of window: ManagedWindow, at current: CGRect) {
        let previous = restoreList.firstIndex { $0.window.isSame(as: window) }.map { restoreList.remove(at: $0) }
        let original =
            previous.flatMap { ReservationTransition.isUnchanged(current, since: $0.lastSet) ? $0.original : nil }
            ?? current
        restoreList.insert(RestoreEntry(window: window, original: original, lastSet: current), at: 0)
        if restoreList.count > Self.restoreLimit { restoreList.removeLast(restoreList.count - Self.restoreLimit) }
    }

    private func restore(_ window: ManagedWindow) {
        guard let index = restoreList.firstIndex(where: { $0.window.isSame(as: window) }) else {
            return fail(.restore, "the manager never placed it")
        }
        let entry = restoreList.remove(at: index)
        guard window.setFrame(entry.original) != nil else { return fail(.restore, "it can't be moved") }
        window.placed(by: avoider)
        cycle.reset()
    }

    // MARK: Finding the window

    /// The frontmost window, if the manager may place it: a standard window that isn't minimized or full screen.
    /// Beeps when there's none.
    private func frontWindow() -> ManagedWindow? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            fail(nil, "no app is in front")
            return nil
        }
        let pid = application.processIdentifier
        // Accessibility calls to itself would block until they time out: its own windows are placed directly.
        if pid == Self.ownProcessIdentifier {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible, !(window is NSPanel),
                window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen), !window.isMiniaturized
            else {
                fail(nil, "Sidelight has no window in front")
                return nil
            }
            return .own(OwnWindow(window: window))
        }
        guard permission.refresh() else {
            fail(nil, "no Accessibility access")
            permission.request()
            return nil
        }
        switch AccessibilityElement.application(pid).focusedWindow {
        case .failure(let error):
            fail(nil, "the focused window can't be read (\(error))")
            return nil
        case .success(let window):
            guard window.isStandardWindow, !window.isMinimized, !window.isFullScreen else {
                fail(nil, "the focused window isn't a standard window, or is minimized or full screen")
                return nil
            }
            return .other(window, pid: pid, launchDate: application.launchDate)
        }
    }

    /// Beeps, the macOS way of saying it can't, and says why in the log.
    private func fail(_ action: WindowAction?, _ reason: String) {
        NSSound.beep()
        let name = action?.rawValue ?? "window action"
        Log.windowManager.notice("Can't do \(name, privacy: .public): \(reason, privacy: .public)")
    }
}

/// One display as the manager sees it, in Accessibility space.
private struct DisplayArea {
    let frame: CGRect
    /// Where tiles go (see ``WindowLayout/workArea(visibleFrame:reservations:padding:)``).
    let workArea: CGRect
    let isPortrait: Bool

    static func all(regions: [PanelRegion], padding: CGFloat) -> [DisplayArea] {
        guard let screenHeight = NSScreen.primary?.frame.height else { return [] }
        func accessibility(_ rect: CGRect) -> CGRect {
            AvoidanceGeometry.accessibilityRect(fromCocoa: rect, primaryScreenHeight: screenHeight)
        }
        return Display.connected().map { display in
            let reservations = regions.filter { $0.displayID == display.id }.map {
                Reservation(frame: accessibility($0.frame), edge: $0.edge, role: $0.role)
            }
            return DisplayArea(
                frame: accessibility(display.frame),
                workArea: WindowLayout.workArea(
                    visibleFrame: accessibility(display.visibleFrame), reservations: reservations, padding: padding),
                isPortrait: display.frame.height > display.frame.width)
        }
    }
}

/// One of Sidelight's own windows, held weakly so a closed one goes away.
private struct OwnWindow {
    weak var window: NSWindow?
}

/// A window the manager places: another app's, through Accessibility, or one of Sidelight's own, directly.
private enum ManagedWindow {
    /// Process identifiers are reused: a window of a later process with the same one isn't this window.
    case other(AccessibilityElement, pid: pid_t, launchDate: Date?)
    case own(OwnWindow)

    func isSame(as other: ManagedWindow) -> Bool {
        switch (self, other) {
        case (.other(let element, let pid, let launchDate), .other(let otherElement, let otherPID, let otherLaunch)):
            pid == otherPID && launchDate == otherLaunch && element.isSameElement(as: otherElement)
        case (.own(let window), .own(let otherWindow)):
            window.window != nil && window.window === otherWindow.window
        default:
            false
        }
    }

    /// In Accessibility space.
    var frame: CGRect? {
        switch self {
        case .other(let element, _, _): element.frame
        case .own(let own): own.window.flatMap { window in Self.accessibility(window.frame) }
        }
    }

    var isPositionSettable: Bool {
        switch self {
        case .other(let element, _, _): element.isPositionSettable
        case .own(let own): own.window != nil
        }
    }

    var isSizeSettable: Bool {
        switch self {
        case .other(let element, _, _): element.isSizeSettable
        case .own(let own): own.window?.styleMask.contains(.resizable) ?? false
        }
    }

    /// Moves it to `frame`, in Accessibility space; returns the frame it took there, `nil` once it's gone.
    func setFrame(_ frame: CGRect) -> CGRect? {
        switch self {
        case .other(let element, _, _):
            return element.setFrame(frame)
        case .own(let own):
            guard let window = own.window, var cocoa = Self.accessibility(frame) else { return nil }
            // AppKit doesn't hold a frame set in code to the window's minimum and maximum sizes, as an app does
            // for an Accessibility resize: so it's sized within them here, and anchored like any other app's.
            let contentMinimum = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize))
            let contentMaximum = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMaxSize))
            let size = WindowLayout.clampedSize(
                cocoa.size,
                minimum: CGSize(
                    width: max(window.minSize.width, contentMinimum.width),
                    height: max(window.minSize.height, contentMinimum.height)),
                maximum: CGSize(
                    width: min(window.maxSize.width, contentMaximum.width),
                    height: min(window.maxSize.height, contentMaximum.height)))
            // Kept at the same top edge: Cocoa's origin is the bottom-left.
            cocoa = CGRect(x: cocoa.minX, y: cocoa.maxY - size.height, width: size.width, height: size.height)
            window.setFrame(cocoa, display: true)
            return Self.accessibility(window.frame)
        }
    }

    /// Tells window avoidance it was placed on purpose, so avoidance never puts it back.
    func placed(by avoider: WindowAvoider) {
        guard case .other(let element, let pid, _) = self else { return }
        avoider.forget(element, pid: pid)
    }

    /// Converts between Cocoa and Accessibility space: the conversion is its own inverse.
    private static func accessibility(_ rect: CGRect) -> CGRect? {
        guard let screenHeight = NSScreen.primary?.frame.height else { return nil }
        return AvoidanceGeometry.accessibilityRect(fromCocoa: rect, primaryScreenHeight: screenHeight)
    }
}
