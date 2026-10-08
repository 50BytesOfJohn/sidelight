// Usage: testwin [x y w h] [moveX moveY]  (Cocoa coords). Opens a standard titled window, optionally moves it
// programmatically after 2 s (triggers AXWindowMoved), prints its frame over 5 s.
import Cocoa
let a = CommandLine.arguments.dropFirst().compactMap { Double($0) }
let r = a.count >= 4 ? NSRect(x: a[0], y: a[1], width: a[2], height: a[3]) : NSRect(x: 40, y: 300, width: 900, height: 500)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let w = NSWindow(contentRect: r, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
w.title = "AvoidanceTest"
w.setFrame(r, display: true)
w.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
print("start frame=\(NSStringFromRect(w.frame))")
var n = 0
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
  n += 1
  if n == 4, a.count >= 6 { w.setFrameOrigin(NSPoint(x: a[4], y: a[5])); print("moved programmatically to \(a[4]),\(a[5])") }
  if n >= 10 { print("end frame=\(NSStringFromRect(w.frame))"); exit(0) }
}
app.run()
