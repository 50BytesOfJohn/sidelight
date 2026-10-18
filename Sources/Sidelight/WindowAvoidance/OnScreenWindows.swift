import CoreGraphics
import Foundation
import SidelightCore

/// The windows the window server is showing right now: each display's active Space, without minimized windows or
/// hidden apps. Their owner and bounds need no permission; their titles would need Screen Recording, and aren't
/// read. One snapshot is a single call, with no app asked anything, so it's cheap enough to take on every app switch.
///
/// Accessibility can't tell which Space a window is on without private API, so the two are matched by app and frame.
/// A window counts as on screen only when one of its app's on-screen windows has its frame and none of the app's
/// other windows does. Anything else is left alone rather than guessed at.
struct OnScreenWindows {
    private let framesByProcess: [pid_t: [CGRect]]

    /// The windows shown, by owner, in Accessibility coordinates; ``current()`` takes them from the window server.
    init(framesByProcess: [pid_t: [CGRect]]) {
        self.framesByProcess = framesByProcess
    }

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
    ///
    /// An app may show windows Accessibility doesn't list (an overlay over its own window, say), so more than one
    /// on-screen window with the frame still counts; another listed window with it doesn't, as that one could be the
    /// one on screen.
    func contains(_ frame: CGRect, of pid: pid_t, siblings: [CGRect]) -> Bool {
        let isShown = framesByProcess[pid, default: []].contains { WindowFrames.isUnchanged($0, since: frame) }
        return isShown && !siblings.contains { WindowFrames.isUnchanged($0, since: frame) }
    }

    /// The apps with a window on screen that overlaps any of `rects`: the only ones worth asking about their windows.
    func processes(overlapping rects: [CGRect]) -> Set<pid_t> {
        Set(
            framesByProcess.compactMap { pid, frames in
                frames.contains { frame in rects.contains { $0.intersects(frame) } } ? pid : nil
            })
    }
}
