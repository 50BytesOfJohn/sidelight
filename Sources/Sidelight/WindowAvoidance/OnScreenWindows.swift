import CoreGraphics
import Foundation
import SidelightCore

/// The windows the window server is showing right now: each display's active Space, without minimized windows or
/// hidden apps. Their owner and bounds need no permission; their titles would need Screen Recording, and aren't
/// read.
///
/// Accessibility can't tell which Space a window is on without private API, so the two are matched by app and frame.
/// A window counts as on screen only when exactly one of its app's on-screen windows has its frame and none of the
/// app's other windows does. Anything else is left alone rather than guessed at.
struct OnScreenWindows {
    private let framesByProcess: [pid_t: [CGRect]]

    /// A snapshot of what's on screen now, in Accessibility coordinates (the window server uses the same).
    static func current() -> OnScreenWindows {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        var frames: [pid_t: [CGRect]] = [:]
        for info in list {
            // Layer 0 holds normal app windows; menus, panels and overlays sit above it.
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                let pid = info[kCGWindowOwnerPID as String] as? Int32,
                let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            frames[pid, default: []].append(frame)
        }
        return OnScreenWindows(framesByProcess: frames)
    }

    /// Whether the window of `pid` at `frame` is on the active Space, told apart from every other window of its app.
    /// `siblings` are the frames of the app's other windows, as Accessibility lists them.
    func contains(_ frame: CGRect, of pid: pid_t, siblings: [CGRect]) -> Bool {
        let matches = framesByProcess[pid, default: []].count { ReservationTransition.isUnchanged($0, since: frame) }
        let twins = siblings.count { ReservationTransition.isUnchanged($0, since: frame) }
        return matches == 1 && twins == 0
    }
}
