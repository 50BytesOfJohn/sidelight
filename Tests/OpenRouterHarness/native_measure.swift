import AppKit
import CoreGraphics
import Foundation

// Read-only metadata for one explicitly supplied disposable PID; no AX writes or permission requests.
guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    fatalError("Usage: native-measure <disposable PID>")
}
let windows =
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
for window in windows where (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid {
    let record: [String: Any] = [
        "pid": pid, "bounds": window[kCGWindowBounds as String] ?? [:],
        "alpha": window[kCGWindowAlpha as String] ?? 0, "layer": window[kCGWindowLayer as String] ?? 0,
    ]
    let json = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    print(String(decoding: json, as: UTF8.self))
}
for screen in NSScreen.screens {
    print("screen frame=\(screen.frame) visible=\(screen.visibleFrame) scale=\(screen.backingScaleFactor)")
}
