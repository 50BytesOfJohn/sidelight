import AppKit
import SidelightCore

/// Slides a panel's content out of its screen edge, or back in from it, as the details panel and the panel it stands
/// in for change places.
///
/// Only the content's layer moves, with Core Animation, so the render server runs the whole slide and frames keep
/// coming however busy the main thread gets meanwhile: SwiftUI laying out the details for the first time, a service
/// starting, apps being listed. Animating the window's frame or alpha through AppKit steps on the main thread instead,
/// and drops frames whenever it's busy. The window sits still at its frame and clips the content sliding past its
/// edge, so nothing fades: fading a layer draws it offscreen, which breaks the blur and glass inside it.
enum EdgeSlide {
    static let entranceDuration: CFTimeInterval = 0.34
    static let exitDuration: CFTimeInterval = 0.2
    /// Long enough for either slide to finish, so other windows move out of the way once it's done, not during it.
    static let settleDelay: Duration = .milliseconds(360)

    /// Off with Reduce Motion: things then appear and disappear in place.
    static var isEnabled: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private static let key = "edgeSlide"
    private static let keyPath = "transform.translation"
    /// Quick to start, long to settle; and its mirror for leaving.
    private static let entranceTiming = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    private static let exitTiming = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.8, 0.2)

    /// Slides `view` in from `edge`: from just past it, or from wherever a slide out still under way has got to.
    static func slideIn(_ view: NSView, from edge: PanelPosition) {
        guard let layer = view.layer else { return }
        let start = currentOffset(of: layer) ?? hiddenOffset(of: view, past: edge)
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = NSValue(size: start)
        animation.toValue = NSValue(size: .zero)
        animation.duration = entranceDuration
        animation.timingFunction = entranceTiming
        layer.add(animation, forKey: key)
    }

    /// Slides `view` out past `edge`, where it stays until it slides in again or ``stop(_:)`` puts it back. Then
    /// `completion` is told whether it got there: `false` when another slide or ``stop(_:)`` overtook it.
    static func slideOut(
        _ view: NSView, past edge: PanelPosition, completion: @escaping (_ finished: Bool) -> Void
    ) {
        guard let layer = view.layer else {
            completion(true)
            return
        }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = NSValue(size: currentOffset(of: layer) ?? .zero)
        animation.toValue = NSValue(size: hiddenOffset(of: view, past: edge))
        animation.duration = exitDuration
        animation.timingFunction = exitTiming
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        animation.delegate = Completion(completion)
        layer.add(animation, forKey: key)
    }

    /// Puts `view` back where it belongs at once, ending any slide.
    static func stop(_ view: NSView) {
        view.layer?.removeAnimation(forKey: key)
    }

    /// Where a slide still under way has the content now; `nil` when nothing slides it.
    private static func currentOffset(of layer: CALayer) -> CGSize? {
        guard layer.animation(forKey: key) != nil,
            let value = layer.presentation()?.value(forKeyPath: keyPath) as? NSValue
        else { return nil }
        return value.sizeValue
    }

    /// Far enough past `edge` that none of the content is left inside the window. The layer moves in its superview's
    /// coordinates, whose y axis points down when that view is flipped.
    private static func hiddenOffset(of view: NSView, past edge: PanelPosition) -> CGSize {
        let size = view.bounds.size
        let up: CGFloat = view.superview?.isFlipped == true ? -1 : 1
        return switch edge {
        case .left: CGSize(width: -size.width, height: 0)
        case .right: CGSize(width: size.width, height: 0)
        case .top: CGSize(width: 0, height: size.height * up)
        case .bottom: CGSize(width: 0, height: -size.height * up)
        }
    }

    /// Tells a slide out's caller when it ended. Core Animation keeps the delegate until then.
    private final class Completion: NSObject, CAAnimationDelegate {
        let handler: (Bool) -> Void

        init(_ handler: @escaping (Bool) -> Void) {
            self.handler = handler
        }

        func animationDidStop(_ animation: CAAnimation, finished: Bool) {
            handler(finished)
        }
    }
}
