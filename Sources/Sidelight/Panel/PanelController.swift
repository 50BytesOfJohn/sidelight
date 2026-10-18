import AppKit
import Observation
import SidelightCore
import SwiftUI

/// Borderless, non-activating panel that never takes key or main status, so it never steals focus.
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// What one panel's content needs to know beyond the shared configuration.
@Observable
final class PanelLayout {
    var displayID: Display.ID
    /// The display's whole frame and the panel's strip on it, in Cocoa screen coordinates.
    var screenFrame: CGRect
    var strip: CGRect
    var position: PanelPosition
    var columns: PanelColumns
    var length: PanelLength
    var alignment: PanelAlignment
    /// Shown, as opposed to hidden with the shortcut. Panels start hidden until shown.
    var isShown = false
    /// Nothing of the window can be seen: the display sleeps, the screen is locked, or the screensaver runs.
    var isOccluded = false

    /// Shown and visible; anything that animates or ticks on its own pauses otherwise.
    var isOnScreen: Bool { isShown && !isOccluded }

    init(_ placement: PanelPlacement) {
        displayID = placement.displayID
        screenFrame = placement.screenFrame
        strip = placement.strip
        position = placement.position
        columns = placement.columns
        length = placement.length
        alignment = placement.alignment
    }

    func update(_ placement: PanelPlacement) {
        displayID = placement.displayID
        screenFrame = placement.screenFrame
        strip = placement.strip
        position = placement.position
        columns = placement.columns
        length = placement.length
        alignment = placement.alignment
    }
}

/// Where one panel goes and how it lays out its widgets.
struct PanelPlacement: Equatable {
    var displayID: Display.ID
    /// The display's whole frame, menu bar and Dock included, which the desktop picture covers.
    var screenFrame: CGRect
    /// The strip along the edge the panel reserves. The window covers all of it, or part of it when fitting.
    var strip: CGRect
    var position: PanelPosition
    var length: PanelLength
    var alignment: PanelAlignment
    var columns: PanelColumns
}

/// Owns one display's panel window: positions it, fits it to its content, and animates moves and resizes.
final class PanelController {
    let window: PanelWindow
    private let layout: PanelLayout
    private var placement: PanelPlacement
    /// The content's natural length along the edge, as last measured by SwiftUI.
    private var contentLength: CGFloat?
    /// Between fading out from the old edge and sliding in at the new one.
    private var isChangingEdge = false
    /// Bumped on every transition so a stale completion handler can tell it was superseded.
    private var transitionGeneration = 0
    private var visibility: WindowVisibility?

    var position: PanelPosition { placement.position }

    init(
        placement: PanelPlacement, environment: AppEnvironment,
        onOcclusionChange: @escaping (_ isOccluded: Bool) -> Void
    ) {
        self.placement = placement
        layout = PanelLayout(placement)
        window = PanelWindow(
            contentRect: placement.strip,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isMovable = false
        window.isReleasedWhenClosed = false

        let rootView = PanelRootView(layout: layout) { [weak self] length in
            self?.contentLengthChanged(length)
        }
        let hostingView = NSHostingView(rootView: rootView.environment(environment))
        hostingView.sizingOptions = []
        // Its own layer, for the content to slide in and out on (see `EdgeSlide`).
        hostingView.wantsLayer = true
        window.contentView = hostingView
        // Measure the content now, so a fitted panel doesn't first show at the strip's full length.
        hostingView.layoutSubtreeIfNeeded()

        visibility = WindowVisibility(of: window) { [layout] isOccluded in
            layout.isOccluded = isOccluded
            onOcclusionChange(isOccluded)
        }
    }

    /// The area other windows should stay out of, or `nil` while the panel is hidden. Always the whole strip, so
    /// the panel fitting its content never makes windows move. Logical rather than visual: a panel fading out to
    /// slide in at another edge already reserves its new strip, and never its old one again.
    var occupiedFrame: CGRect? {
        layout.isShown ? placement.strip : nil
    }

    /// The window's frame for the current placement and content.
    private var windowFrame: CGRect {
        let stripLength = placement.position.isBar ? placement.strip.width : placement.strip.height
        return PanelGeometry.frame(
            inStrip: placement.strip,
            position: placement.position,
            length: placement.length,
            alignment: placement.alignment,
            contentLength: contentLength ?? stripLength
        )
    }

    /// Shows the window; `animated` slides its content in from its edge, as when the details panel gives it back.
    func show(animated: Bool = false) {
        layout.isShown = true
        window.alphaValue = 1
        if let content = window.contentView {
            if animated && EdgeSlide.isEnabled {
                EdgeSlide.slideIn(content, from: layout.position)
            } else {
                EdgeSlide.stop(content)
            }
        }
        window.orderFrontRegardless()
    }

    /// Hides the window; `animated` first slides its content out past its edge, as when the details panel takes its
    /// place. Its widgets stop drawing at once either way.
    func hide(animated: Bool = false) {
        layout.isShown = false
        guard animated, EdgeSlide.isEnabled, window.isVisible, let content = window.contentView else {
            if let content = window.contentView { EdgeSlide.stop(content) }
            window.orderOut(nil)
            return
        }
        // Stays slid out once ordered out, so it never shows at rest for a moment before sliding in again.
        EdgeSlide.slideOut(content, past: layout.position) { [weak self] finished in
            // Shown again meanwhile.
            guard finished, let self, !layout.isShown else { return }
            window.orderOut(nil)
        }
    }

    /// Hides the window for good and releases its SwiftUI content.
    func close() {
        transitionGeneration += 1
        layout.isShown = false
        window.orderOut(nil)
        window.contentView = nil
        visibility?.invalidate()
        visibility = nil
    }

    /// Moves the panel to `newPlacement`. Edge changes fade out and slide in; other changes animate the frame
    /// unless `animated` is false (the screen itself changed, so there's nothing sensible to animate from).
    func move(to newPlacement: PanelPlacement, animated: Bool) {
        transitionGeneration += 1
        let previousPosition = placement.position
        placement = newPlacement

        if newPlacement.position != previousPosition || isChangingEdge {
            // The content switches layout while the window is faded out.
            moveToNewEdge(generation: transitionGeneration)
            return
        }
        layout.update(newPlacement)
        setWindowFrame(windowFrame, animated: animated)
    }

    /// Fitted panels follow their content: widgets appearing, disappearing or changing size.
    private func contentLengthChanged(_ newLength: CGFloat) {
        guard newLength != contentLength else { return }
        // The first measurement places the window; later ones animate it.
        let isFirstMeasurement = contentLength == nil
        contentLength = newLength
        guard placement.length == .fit, !isChangingEdge else { return }
        setWindowFrame(windowFrame, animated: !isFirstMeasurement)
    }

    private func setWindowFrame(_ frame: CGRect, animated: Bool) {
        guard frame != window.frame else { return }
        guard animated, window.isVisible else {
            window.setFrame(frame, display: true)
            return
        }
        // SwiftUI animates the content layout with matching timing (see `Motion.layout`).
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            window.animator().setFrame(frame, display: true)
        }
    }

    /// Fade out, jump, then slide in from the new edge, so no stale frame is ever visible.
    private func moveToNewEdge(generation: Int) {
        isChangingEdge = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.slideIn(generation: generation)
            }
        }
    }

    private func slideIn(generation: Int) {
        guard generation == transitionGeneration else { return }
        isChangingEdge = false
        layout.update(placement)
        // Lay the content out for the new edge first, so a fitted window knows its new length.
        window.contentView?.layoutSubtreeIfNeeded()
        let target = windowFrame
        let offset = PanelMetrics.entranceOffset(for: placement.position)
        window.setFrame(target.offsetBy(dx: offset.dx, dy: offset.dy), display: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(target, display: true)
        }
    }
}
