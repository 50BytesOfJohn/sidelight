import AppKit
import Observation
import SidelightCore
import os

/// Moves and resizes the frontmost window into tiles on a shortcut (see ``WindowAction`` and ``WindowLayout``), always
/// clear of the panel.
///
/// Not a data service: nothing runs between presses. It watches nothing, polls nothing, and while it's off it asks
/// for no access and keeps nothing. The only thing it keeps while on is the last press, for cycling a half's size;
/// where a window was before it first placed one belongs to ``WindowPlacer``, along with every other window
/// Sidelight has moved.
///
/// It knows nothing of window avoidance. Its tiles are clear of the panels because ``WorkArea`` says where windows
/// go, and avoidance leaves them because the placer says someone asked for them to be there.
@Observable
final class WindowManager {
    @ObservationIgnored private(set) var settings = WindowManagerSettings()
    /// The strips the panels keep clear, which tiles stay out of; empty while the panels are hidden.
    @ObservationIgnored var occupiedRegions: () -> [PanelRegion] = { [] }

    @ObservationIgnored private let permission: AccessibilityPermission
    @ObservationIgnored private let placer: WindowPlacer
    @ObservationIgnored private var cycle = SizeCycle()
    /// The window the last press placed, which ``cycle`` is about.
    @ObservationIgnored private var lastWindow: ManagedWindow?

    private static let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier

    init(permission: AccessibilityPermission, placer: WindowPlacer) {
        self.permission = permission
        self.placer = placer
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
            placer.forgetDeliberatePlacements()
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
        let displays = ScreenLayout.areas(regions: occupiedRegions(), padding: CGFloat(settings.padding))
        guard let source = WindowLayout.sourceDisplay(of: current, among: displays.map(\.frame)) else {
            return fail(action, "no display")
        }
        let isSameWindow = lastWindow?.isSame(as: window) ?? false
        let now = ContinuousClock.now

        switch action {
        case .restore:
            restore(window, among: displays)
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
                guard
                    let accepted = place(
                        window, at: tile, as: placement.action, step: placement.step, pressed: action, on: area)
                else { return fail(action, "it can't be moved") }
                cycle.record(action, placement: placement, accepted: accepted, now: now)
            } else {
                let moved = WindowLayout.transfer(
                    current, from: displays[source].workArea.rect, to: area.workArea.rect)
                guard let accepted = place(window, at: moved, as: nil, step: 0, pressed: action, on: area) else {
                    return fail(action, "it can't be moved")
                }
                cycle.record(action, placement: nil, accepted: accepted, now: now)
            }
        default:
            let step = cycle.step(
                for: action, isSameWindow: isSameWindow, frame: current, now: now, cycles: settings.cyclesSizes)
            let area = displays[source]
            guard let tile = frame(for: action, step: step, size: current.size, on: area) else { return }
            guard let accepted = place(window, at: tile, as: action, step: step, pressed: action, on: area) else {
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
        if action == .center { return WindowLayout.centered(size, in: display.workArea.rect) }
        return WindowLayout.frame(
            for: action, step: step, in: display.workArea.rect, gap: CGFloat(settings.gap),
            isPortrait: display.isPortrait)
    }

    /// Puts `window` at `frame`, as the tile for `tile` (`nil` for a move to another display that isn't re-applying
    /// one), from pressing `pressed`.
    ///
    /// A window of a fixed size keeps it, centred where the tile is; one the app sizes differently is anchored to the
    /// tile's edges (see ``WindowLayout/anchored(_:for:tile:in:isPortrait:)``), which the placer applies inside the
    /// same placement. For a leading-anchored tile the window is already at the tile's origin by then, so there's
    /// usually nothing to correct. Returns the frame the app accepted; `nil` when it can't be moved.
    private func place(
        _ window: ManagedWindow, at frame: CGRect, as tile: WindowAction?, step: Int, pressed: WindowAction,
        on display: DisplayArea
    ) -> CGRect? {
        let area = display.workArea
        guard window.isPositionSettable else { return nil }
        var requested = frame
        if !window.isSizeSettable {
            guard let current = window.frame else { return nil }
            let centered = CGRect(
                x: (frame.midX - current.width / 2).rounded(.down), y: (frame.midY - current.height / 2).rounded(.down),
                width: current.width, height: current.height)
            requested = WindowLayout.fitted(centered, in: area)
        }
        let isPortrait = display.isPortrait
        return placer.place(
            window, at: requested, intent: .manager(tile ?? pressed, step: tile == nil ? 0 : step), on: display,
            correcting: { accepted in
                guard let tile else { return WindowLayout.fitted(accepted, in: area) }
                return WindowLayout.anchored(
                    accepted.size, for: tile, tile: requested, in: area, isPortrait: isPortrait)
            },
            reason: pressed.rawValue)
    }

    // MARK: Restoring

    /// Puts `window` back where Sidelight first found it, and forgets it: there's nothing left to put back.
    private func restore(_ window: ManagedWindow, among displays: [DisplayArea]) {
        guard let original = placer.baseline(of: window) else {
            return fail(.restore, "the manager never placed it")
        }
        let display = ScreenLayout.display(of: original, among: displays)
        guard placer.place(window, at: original, intent: .restore, on: display, reason: "restore") != nil else {
            return fail(.restore, "it can't be moved")
        }
        placer.forget(window)
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
