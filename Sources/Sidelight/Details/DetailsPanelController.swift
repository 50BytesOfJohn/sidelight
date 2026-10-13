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

    init(placement: DetailsPlacement) {
        self.placement = placement
    }
}

/// Owns the details panel's window while a session is open: places it, slides it in, gives it focus, and releases
/// its content when it closes. Nothing is kept around once it's closed.
final class DetailsPanelController {
    let window: DetailsWindow
    private let layout: DetailsLayout

    var placement: DetailsPlacement { layout.placement }

    init(
        session: DetailsSession, placement: DetailsPlacement, environment: AppEnvironment,
        close: @escaping () -> Void
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
    }

    /// Shows the window: sliding in from its edge the first time, or fading in with Reduce Motion. `focusing`
    /// makes it key, so typing goes to its search field, without activating Sidelight.
    func show(focusing: Bool, slidingIn: Bool) {
        layout.isShown = true
        let frame = layout.placement.frame
        if slidingIn && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let offset = PanelMetrics.entranceOffset(for: layout.placement.edge)
            window.alphaValue = 0
            window.setFrame(frame.offsetBy(dx: offset.dx, dy: offset.dy), display: true)
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
                window.animator().setFrame(frame, display: true)
            }
        } else if slidingIn {
            window.alphaValue = 0
            window.setFrame(frame, display: true)
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                window.animator().alphaValue = 1
            }
        } else {
            window.alphaValue = 1
            window.setFrame(frame, display: true)
            window.orderFrontRegardless()
        }
        if focusing { window.makeKey() }
    }

    /// Brings it forward and gives it focus, as asking for the open session again does.
    func focus() {
        window.orderFrontRegardless()
        window.makeKey()
    }

    /// Hides it with the panels, keeping its content: search, choices and scroll position come back with it.
    func hide() {
        layout.isShown = false
        window.orderOut(nil)
    }

    /// Follows its display's new geometry, or the panel's new edge, without animating from a stale frame.
    func move(to placement: DetailsPlacement) {
        guard placement != layout.placement else { return }
        layout.placement = placement
        window.setFrame(placement.frame, display: true)
    }

    /// Hides it for good and releases its content.
    func close() {
        layout.isShown = false
        window.orderOut(nil)
        window.contentView = nil
    }
}
