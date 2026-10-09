import Cocoa
import ApplicationServices

// MARK: - Window avoidance (Accessibility API)

final class Avoider {
    static let shared = Avoider()
    var observers: [pid_t: AXObserver] = [:]
    var panelFrameCocoa: () -> NSRect? = { nil }
    private var pending: [(AXUIElement, Date, String)] = []
    private var mouseTimer: Timer?
    private var trustTimer: Timer?
    let myPid = getpid()

    var trusted: Bool { AXIsProcessTrusted() }

    func start(prompt: Bool) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) { registerAll() }
        else {
            Log.avoidance.info("Accessibility not trusted yet; polling every 3s")
            trustTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
                if AXIsProcessTrusted() { t.invalidate(); self?.registerAll() }
            }
        }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.register(app) }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.register(app)
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if let o = self?.observers.removeValue(forKey: app.processIdentifier) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
            }
        }
    }

    func registerAll() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular { register(app) }
        Log.avoidance.info("AX observers registered: \(self.observers.count)")
    }

    func register(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != myPid, observers[pid] == nil, app.activationPolicy == .regular, AXIsProcessTrusted() else { return }
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, element, notification, refcon in
            let me = Unmanaged<Avoider>.fromOpaque(refcon!).takeUnretainedValue()
            me.handle(element, notification as String)
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let o = obs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        var ok = 0
        for n in [kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification, kAXWindowMiniaturizedNotification] {
            if AXObserverAddNotification(o, appEl, n as CFString, ref) == .success { ok += 1 }
        }
        guard ok > 0 else {
            // freshly launched apps often aren't AX-ready yet; retry a few times
            let tries = retries[pid, default: 0]
            if tries < 10 { retries[pid] = tries + 1; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.register(app) } }
            return
        }
        retries[pid] = nil
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
        observers[pid] = o
        // windows created before we started observing
        var v: CFTypeRef?
        if mode != .off, AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &v) == .success, let wins = v as? [AXUIElement] {
            for w in wins { fix(w, eventDate: Date(), reason: "registered") }
        }
    }
    var retries: [pid_t: Int] = [:]

    func handle(_ el: AXUIElement, _ notif: String) {
        guard mode != .off else { return }
        if notif == (kAXWindowMiniaturizedNotification as String) { return }
        let now = Date()
        // While the user is dragging/resizing, wait for mouse-up instead of fighting the drag.
        if NSEvent.pressedMouseButtons != 0 {
            if !pending.contains(where: { CFEqual($0.0, el) }) { pending.append((el, now, notif)) }
            if mouseTimer == nil {
                mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
                    guard let self, NSEvent.pressedMouseButtons == 0 else { return }
                    t.invalidate(); self.mouseTimer = nil
                    let p = self.pending; self.pending = []
                    for (e, d, n) in p { self.fix(e, eventDate: d, reason: n + "+mouseup") }
                }
            }
            return
        }
        fix(el, eventDate: now, reason: notif)
    }

    func fixAll() {
        var n = 0
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != myPid {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &v) == .success, let wins = v as? [AXUIElement] else { continue }
            for w in wins { if fix(w, eventDate: Date(), reason: "fixAll") { n += 1 } }
        }
        Log.avoidance.info("fixAll: fixed \(n) windows")
    }

    private func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }
    private func frame(_ el: AXUIElement) -> CGRect? {
        guard let pv: AXValue = attr(el, kAXPositionAttribute), let sv: AXValue = attr(el, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv, .cgPoint, &p); AXValueGetValue(sv, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }
    private func setPos(_ el: AXUIElement, _ p: CGPoint) { var p = p; if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) } }
    private func setSize(_ el: AXUIElement, _ s: CGSize) { var s = s; if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) } }

    /// Converts a Cocoa (bottom-left origin) rect to AX/CG global coords (top-left of primary screen).
    static func toAX(_ r: NSRect) -> CGRect {
        let h = NSScreen.screens[0].frame.height
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// Which screen edge the panel occupies; avoidance clips/shifts along that edge's axis.
    var edge: PanelPosition = .left
    var mode: AvoidMode { ConfigStore.shared.config.avoidMode }

    // Canonical space: every edge is mapped so the panel sits on the *left* (min-x) side, the
    // left-edge logic runs there, and the result is mapped back. right = mirror x; top = swap axes;
    // bottom = swap axes + mirror.
    static func canon(_ r: CGRect, _ e: PanelPosition) -> CGRect {
        switch e {
        case .left:   return r
        case .right:  return CGRect(x: -r.maxX, y: r.minY, width: r.width, height: r.height)
        case .top:    return CGRect(x: r.minY, y: r.minX, width: r.height, height: r.width)
        case .bottom: return CGRect(x: -r.maxY, y: r.minX, width: r.height, height: r.width)
        }
    }
    static func uncanon(_ c: CGRect, _ e: PanelPosition) -> CGRect {
        switch e {
        case .left:   return c
        case .right:  return CGRect(x: -c.maxX, y: c.minY, width: c.width, height: c.height)
        case .top:    return CGRect(x: c.minY, y: c.minX, width: c.height, height: c.width)
        case .bottom: return CGRect(x: c.minY, y: -c.maxX, width: c.height, height: c.width)
        }
    }

    @discardableResult
    func fix(_ win: AXUIElement, eventDate: Date, reason: String) -> Bool {
        guard mode != .off, let panelCocoa = panelFrameCocoa(), let screen = NSScreen.screens.first else { return false }
        var pid: pid_t = 0; AXUIElementGetPid(win, &pid)
        if pid == myPid { return false }
        let subrole: String? = attr(win, kAXSubroleAttribute)
        guard subrole == (kAXStandardWindowSubrole as String) else { return false }
        if let fs: Bool = attr(win, "AXFullScreen"), fs { return false }
        if let mini: Bool = attr(win, kAXMinimizedAttribute), mini { return false }
        guard let f = frame(win) else { return false }
        let panelAX = Self.toAX(panelCocoa)
        guard f.intersects(panelAX) else { return false }
        let e = edge
        let P = Self.canon(panelAX, e), F = Self.canon(f, e), V = Self.canon(Self.toAX(screen.visibleFrame), e)
        let x = P.maxX + 8
        let y = max(F.minY, V.minY)
        let h = min(F.height, V.maxY - y)
        // shift = move away from the panel keeping size; clip = keep the far edge, shrink;
        // smart = clip if the near edge sits on the visible-frame edge (snapped/maximized), else shift.
        var action = (mode == .clip || (mode == .smart && abs(F.minX - V.minX) <= 2)) ? "clip" : "shift"
        if action == "clip" && (F.maxX - x) < 0.4 * F.width { action = "shift(clip<40%)" }
        func apply(_ c: CGRect) {
            let r = Self.uncanon(c, e)
            setPos(win, r.origin); setSize(win, r.size)
            if let g = frame(win), abs(g.minX - r.minX) > 1 || abs(g.minY - r.minY) > 1 { setPos(win, r.origin) }
        }
        let shiftRect = CGRect(x: x, y: y, width: min(F.width, V.maxX - x), height: h)
        if action == "clip" {
            let t = CGRect(x: x, y: y, width: F.maxX - x, height: h)
            apply(t)
            if let g = frame(win), Self.canon(g, e).width > t.width + 2 { action = "shift(minSize)"; apply(shiftRect) } // app enforces a minimum size
        } else { apply(shiftRect) }
        let after = frame(win) ?? .zero
        let ms = Date().timeIntervalSince(eventDate) * 1000
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "\(pid)"
        let title: String = attr(win, kAXTitleAttribute) ?? ""
        Log.avoidance.debug("fix edge=\(e.rawValue) mode=\(self.mode.rawValue) action=\(action) app=\(appName, privacy: .public) title=\"\(String(title.prefix(40)))\" event=\(reason) delay_ms=\(ms, format: .fixed(precision: 1)) from=\(NSStringFromRect(f)) to=\(NSStringFromRect(after))")
        return true
    }
}
