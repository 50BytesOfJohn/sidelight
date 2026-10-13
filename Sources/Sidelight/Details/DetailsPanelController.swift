import AppKit
import Carbon.HIToolbox
import Observation
import SidelightCore
import SwiftUI

/// The details panel's window. Borderless and floating like the panel, and it never activates Sidelight, so the app
/// you were in stays frontmost. Unlike the panel it can take key status, so its search field takes typing.
final class DetailsWindow: NSPanel {
    /// Escape, ⌘W and the close button all close it.
    var onClose: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape closes, unless it's ending text input that's still being composed (an input method's candidates).
    /// Handled here, before any view: a text field would take it to offer completions.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, Int(event.keyCode) == kVK_Escape,
            event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
            !((firstResponder as? NSTextView)?.hasMarkedText() ?? false)
        {
            onClose()
            return
        }
        super.sendEvent(event)
    }

    /// While another app is active, Sidelight's Edit menu doesn't see ⌘C and the like, so the standard editing
    /// shortcuts go to the focused field directly.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control),
            let key = event.charactersIgnoringModifiers?.lowercased()
        else { return false }
        let isShifted = flags.contains(.shift)
        let action: Selector? =
            switch (key, isShifted) {
            case ("x", false): #selector(NSText.cut(_:))
            case ("c", false): #selector(NSText.copy(_:))
            case ("v", false): #selector(NSText.paste(_:))
            case ("a", false): #selector(NSText.selectAll(_:))
            case ("z", false): Selector(("undo:"))
            case ("z", true): Selector(("redo:"))
            default: nil
            }
        if key == "w" && !isShifted {
            onClose()
            return true
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

/// Where the details panel goes on a display, in Cocoa screen coordinates.
struct DetailsPlacement: Equatable {
    var displayID: Display.ID
    /// The display's whole frame, which the desktop picture covers.
    var screenFrame: CGRect
    var visibleFrame: CGRect
    var edge: PanelPosition
    var frame: CGRect

    /// In place of the panel at `position` on `display`.
    init(display: Display, replacing position: PanelPosition) {
        displayID = display.id
        screenFrame = display.frame
        visibleFrame = display.visibleFrame
        edge = DetailsGeometry.edge(replacing: position)
        frame = DetailsGeometry.frame(in: display.visibleFrame, replacing: position)
    }
}

/// What the details panel's content needs to know about where it is.
@Observable
final class DetailsLayout {
    var placement: DetailsPlacement
    /// Shown, as opposed to hidden with the panels.
    var isShown = false
    /// Nothing of it can be seen: the display sleeps, the screen is locked, or something covers it.
    var isOccluded = false

    /// Shown and visible; anything that ticks on its own pauses otherwise.
    var isOnScreen: Bool { isShown && !isOccluded }

    init(placement: DetailsPlacement) {
        self.placement = placement
    }
}

/// The app that was frontmost when the details panel took focus, to give it back to on close. Process identifiers are
/// reused, so the launch date tells a later process apart.
private struct FocusOwner {
    let processIdentifier: pid_t
    let launchDate: Date?

    init?(_ application: NSRunningApplication?) {
        guard let application, application != .current else { return nil }
        processIdentifier = application.processIdentifier
        launchDate = application.launchDate
    }

    func isSame(as application: NSRunningApplication?) -> Bool {
        application?.processIdentifier == processIdentifier && application?.launchDate == launchDate
    }
}

/// Owns the details panel's window while a session is open: places it, slides it in, gives it focus, and releases
/// its content when it closes. Nothing is kept around once it's closed.
///
/// It watches its own visibility, apart from the panel it stands in for: that panel is ordered out on purpose, and
/// mustn't make the details panel count as unseen.
final class DetailsPanelController {
    let window: DetailsWindow
    private let layout: DetailsLayout
    private var visibility: WindowVisibility?
    /// Whose window had focus before the details panel took it.
    private var focusOwner: FocusOwner?

    var placement: DetailsPlacement { layout.placement }

    /// - Parameters:
    ///   - close: Closes the session, from the close button, Escape or ⌘W.
    ///   - onVisibilityChange: Told when it can no longer be seen at all, or can again.
    init(
        session: DetailsSession, placement: DetailsPlacement, environment: AppEnvironment,
        close: @escaping () -> Void, onVisibilityChange: @escaping (_ isOnScreen: Bool) -> Void
    ) {
        layout = DetailsLayout(placement: placement)
        window = DetailsWindow(
            contentRect: placement.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // As the panel: above other apps' windows, on every Space and over full-screen apps, out of ⌘-Tab.
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        // Stays open while you work in another app, and only closes when asked to.
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.onClose = close
        window.setAccessibilityRole(.window)
        window.setAccessibilitySubrole(.dialog)
        window.setAccessibilityTitle(session.content.title)

        let rootView = DetailsPanelView(session: session, layout: layout, close: close)
        let hostingView = NSHostingView(rootView: rootView.environment(environment))
        hostingView.sizingOptions = []
        window.contentView = hostingView

        visibility = WindowVisibility(of: window) { [layout] isOccluded in
            layout.isOccluded = isOccluded
            onVisibilityChange(layout.isOnScreen)
        }
    }

    /// Shows the window: sliding in from its edge the first time, or fading in with Reduce Motion. `focusing`
    /// makes it key, so typing goes to its search field, without activating Sidelight.
    func show(focusing: Bool, slidingIn: Bool) {
        layout.isShown = true
        let frame = layout.placement.frame
        if slidingIn && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let offset = PanelMetrics.entranceOffset(for: layout.placement.edge)
            settle(frame: frame.offsetBy(dx: offset.dx, dy: offset.dy), alpha: 0)
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
                window.animator().setFrame(frame, display: true)
            }
        } else if slidingIn {
            settle(frame: frame, alpha: 0)
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                window.animator().alphaValue = 1
            }
        } else {
            settle(frame: frame, alpha: 1)
            window.orderFrontRegardless()
        }
        if focusing { focus() }
    }

    /// Brings it forward and gives it focus, as asking for the open session again does. Remembers which app had
    /// focus before, the first time, to give it back on close.
    func focus() {
        if !window.isKeyWindow, focusOwner == nil {
            focusOwner = FocusOwner(NSWorkspace.shared.frontmostApplication)
        }
        window.orderFrontRegardless()
        window.makeKey()
    }

    /// Hides it with the panels, keeping its content: search, choices and scroll position come back with it.
    func hide() {
        layout.isShown = false
        settle(frame: layout.placement.frame, alpha: 1)
        window.orderOut(nil)
    }

    /// Follows its display's new geometry, or the panel's new edge, without animating from a stale frame. An
    /// entrance still under way ends where the panel now goes.
    func move(to placement: DetailsPlacement) {
        guard placement != layout.placement else { return }
        layout.placement = placement
        settle(frame: placement.frame, alpha: window.isVisible ? 1 : window.alphaValue)
    }

    /// Hides it for good and releases its content. If it had focus, and the app that had focus before it is still
    /// the frontmost one, that app gets it back; after switching to another app, focus stays where it went.
    func close() {
        let hadFocus = window.isKeyWindow
        layout.isShown = false
        settle(frame: layout.placement.frame, alpha: 1)
        window.orderOut(nil)
        window.contentView = nil
        visibility?.invalidate()
        visibility = nil
        if hadFocus { returnFocus() }
        focusOwner = nil
    }

    private func returnFocus() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard let owner = focusOwner, owner.isSame(as: frontmost), let frontmost else { return }
        // Sidelight never became active, so it hands activation over explicitly rather than taking it.
        NSApp.yieldActivation(to: frontmost)
        _ = frontmost.activate(from: .current, options: [])
    }

    /// Puts the window at `frame` and `alpha` at once, ending any animation still under way, so a hide, a move or a
    /// close overtaking the entrance never leaves it heading somewhere stale.
    private func settle(frame: CGRect, alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().alphaValue = alpha
            window.animator().setFrame(frame, display: true)
        }
    }
}
