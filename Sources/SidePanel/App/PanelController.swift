import Cocoa
import SwiftUI
import Combine

final class SidePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the NSPanel; maps config (position × size) to a frame and animates changes.
final class PanelController {
    static let barThickness: CGFloat = 44
    let panel: SidePanel
    private var current: AppConfig
    private var sub: AnyCancellable?
    private var generation = 0

    init() {
        current = ConfigStore.shared.config
        panel = SidePanel(contentRect: Self.frame(for: current), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        let host = NSHostingView(rootView: PanelRoot())
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(Self.frame(for: current), display: true)
        Avoider.shared.edge = current.position
        sub = ConfigStore.shared.$config.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] in self?.apply($0) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; self.panel.setFrame(Self.frame(for: self.current), display: true); self.logFrame("screen-change")
        }
    }

    static func frame(for c: AppConfig) -> NSRect {
        let vf = NSScreen.screens[0].visibleFrame
        let w = c.size.width, t = barThickness
        switch c.position {
        case .left:   return NSRect(x: vf.minX, y: vf.minY, width: w, height: vf.height)
        case .right:  return NSRect(x: vf.maxX - w, y: vf.minY, width: w, height: vf.height)
        case .top:    return NSRect(x: vf.minX, y: vf.maxY - t, width: vf.width, height: t)
        case .bottom: return NSRect(x: vf.minX, y: vf.minY, width: vf.width, height: t)
        }
    }

    var thickness: CGFloat { current.position.isBar ? Self.barThickness : current.size.width }

    func show() { panel.alphaValue = 1; panel.orderFrontRegardless() }
    func toggle() { if panel.isVisible { panel.orderOut(nil) } else { show() } }

    private func apply(_ new: AppConfig) {
        let old = current
        current = new
        Avoider.shared.edge = new.position
        if new.hotkey != old.hotkey { HotkeyManager.shared.register(new.hotkey) }
        let target = Self.frame(for: new)
        generation += 1; let gen = generation
        if new.position != old.position {
            // position: fade out → jump → slide in from the new edge. No stale frame is left behind.
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.14
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, gen == self.generation else { return }
                var start = target
                switch new.position {
                case .left: start.origin.x -= 24
                case .right: start.origin.x += 24
                case .top: start.origin.y += 16
                case .bottom: start.origin.y -= 16
                }
                self.panel.setFrame(start, display: true)
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.3
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.panel.animator().alphaValue = 1
                    self.panel.animator().setFrame(target, display: true)
                }, completionHandler: { [weak self] in self?.logFrame("position") })
            })
        } else if target != panel.frame {
            // size: animate the window frame; SwiftUI animates the content layout with the same spring-ish timing
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(target, display: true)
            }, completionHandler: { [weak self] in self?.logFrame("size") })
        }
    }

    func logFrame(_ reason: String) {
        let vf = NSScreen.screens[0].visibleFrame
        appendLog("frames.log", "layout reason=\(reason) position=\(current.position.rawValue) size=\(current.effectiveSize.rawValue) frame=\(NSStringFromRect(panel.frame)) visibleFrame=\(NSStringFromRect(vf)) alpha=\(panel.alphaValue) visible=\(panel.isVisible)")
    }
}
