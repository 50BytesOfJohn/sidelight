import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var panelController: PanelController!
    var statusItem: NSStatusItem!
    let models = AppModels.shared
    var store: ConfigStore { .shared }
    var codexSub: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        panelController = PanelController()
        panelController.show()

        // Codex app-server only runs while a Codex widget is configured
        syncCodex(store.config)
        codexSub = store.$config.sink { [weak self] c in DispatchQueue.main.async { self?.syncCodex(c) } }

        Avoider.shared.panelFrameCocoa = { [weak self] in
            guard let p = self?.panelController.panel, p.isVisible, p.alphaValue > 0.5 else { return nil }; return p.frame
        }
        Avoider.shared.start(prompt: true)

        HotkeyManager.shared.action = { [weak self] in self?.panelController.toggle() }
        HotkeyManager.shared.register(store.config.hotkey)

        setupMainMenu()
        setupStatusItem()
    }

    func applicationWillTerminate(_ n: Notification) { models.np.stop(); models.codex.stop() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowCoordinator.shared.showManager() }
        return true
    }

    func syncCodex(_ c: AppConfig) {
        let want = c.widgets.contains { $0.kind == "codex" && (c.position.isBar ? $0.inBar : $0.inSide) }
        if want && !models.codex.enabled { models.codex.start() }
        if !want && models.codex.enabled { models.codex.stop() }
    }

    // MARK: menus

    func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "Widgets…", action: #selector(openManager), keyEquivalent: "1").target = self
        app.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Sidelight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidelight")
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu
    }

    func item(_ t: String, _ sel: Selector, on: Bool? = nil, key: String = "", rep: Any? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: sel, keyEquivalent: key); i.target = self
        if let on { i.state = on ? .on : .off }
        i.representedObject = rep
        return i
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let c = store.config
        menu.removeAllItems()
        let t = item(panelController.panel.isVisible ? "Hide panel" : "Show panel", #selector(togglePanel))
        t.toolTip = "Global shortcut: \(c.hotkey.display)"
        menu.addItem(t)
        menu.addItem(item("Widgets…", #selector(openManager)))
        menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(.separator())
        func sub(_ title: String, _ items: [NSMenuItem]) { let m = NSMenu(); items.forEach { m.addItem($0) }; let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.submenu = m; menu.addItem(i) }
        sub("Position", PanelPosition.allCases.map { item($0.title, #selector(setPosition(_:)), on: c.position == $0, rep: $0.rawValue) })
        sub("Size", PanelSize.allCases.map { item($0.title, #selector(setSize(_:)), on: c.size == $0, rep: $0.rawValue) })
        sub("Style", DisplayMode.allCases.map { item($0.title, #selector(setMode(_:)), on: c.mode == $0, rep: $0.rawValue) })
        sub("Window avoidance", AvoidMode.allCases.map { item($0.rawValue.capitalized, #selector(setAvoid(_:)), on: c.avoidMode == $0, rep: $0.rawValue) })
        menu.addItem(item("Animated background", #selector(toggleAnim), on: c.animatedBG))
        menu.addItem(.separator())
        menu.addItem(item("Fix all windows now", #selector(fixAll)))
        menu.addItem(item(Avoider.shared.trusted ? "Accessibility: granted" : "Grant Accessibility…", #selector(openAXSettings)))
        menu.addItem(item("Configure Rectangle for panel…", #selector(configureRectangle)))
        menu.addItem(item("Revert Rectangle config…", #selector(revertRectangle)))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), key: "q"))
    }

    @objc func togglePanel() { panelController.toggle() }
    @objc func openManager() { WindowCoordinator.shared.showManager() }
    @objc func openSettings() { WindowCoordinator.shared.showSettings() }
    @objc func setPosition(_ s: NSMenuItem) { if let v = s.representedObject as? String, let p = PanelPosition(rawValue: v) { store.config.position = p } }
    @objc func setSize(_ s: NSMenuItem) { if let v = s.representedObject as? String, let p = PanelSize(rawValue: v) { store.config.size = p } }
    @objc func setMode(_ s: NSMenuItem) { if let v = s.representedObject as? String, let p = DisplayMode(rawValue: v) { store.config.mode = p } }
    @objc func setAvoid(_ s: NSMenuItem) { if let v = s.representedObject as? String, let p = AvoidMode(rawValue: v) { store.config.avoidMode = p } }
    @objc func toggleAnim() { store.config.animatedBG.toggle() }
    @objc func fixAll() { Avoider.shared.fixAll() }
    @objc func openAXSettings() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: Rectangle (only when the user clicks + confirms)

    static let rectangleIDs = ["com.knollsoft.Rectangle", "com.knollsoft.Hookshot"]
    var rectangleGap: Int { Int(panelController.thickness) + 8 }
    func installedRectangleIDs() -> [String] { Self.rectangleIDs.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil } }
    func runDefaults(_ args: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults"); p.arguments = args
        try? p.run(); p.waitUntilExit(); Log.app.info("defaults \(args.joined(separator: " ")) -> \(p.terminationStatus)")
    }
    func restartRectangle(ids: [String], change: @escaping () -> Void) {
        var relaunch: [URL] = []
        for id in ids { for a in NSRunningApplication.runningApplications(withBundleIdentifier: id) { a.terminate(); if let u = a.bundleURL { relaunch.append(u) } } }
        DispatchQueue.global().async {
            for _ in 0..<50 where ids.contains(where: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) { usleep(100_000) }
            change()
            DispatchQueue.main.async { for u in relaunch { NSWorkspace.shared.openApplication(at: u, configuration: NSWorkspace.OpenConfiguration()) } }
        }
    }
    func confirm(_ title: String, _ text: String, ok: String = "Continue", cancel: String? = "Cancel") -> Bool {
        NSApp.activate()
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        a.addButton(withTitle: ok); if let cancel { a.addButton(withTitle: cancel) }
        return a.runModal() == .alertFirstButtonReturn
    }
    @objc func configureRectangle() {
        let ids = installedRectangleIDs()
        guard !ids.isEmpty else { _ = confirm("Rectangle not found", "Neither Rectangle nor Rectangle Pro is installed.", ok: "OK", cancel: nil); return }
        let key = store.config.position.rectangleKey, gap = rectangleGap
        guard confirm("Configure Rectangle for the \(store.config.position.rawValue) panel?",
                      "This will quit \(ids.joined(separator: ", ")), set \(key) = \(gap) and screenEdgeGapsOnMainScreenOnly = true, then relaunch it.\n\nOther edge gaps are left unchanged. Use \"Revert Rectangle config…\" to undo.") else { return }
        restartRectangle(ids: ids) { [weak self] in
            for id in ids {
                self?.runDefaults(["write", id, key, "-int", "\(gap)"])
                self?.runDefaults(["write", id, "screenEdgeGapsOnMainScreenOnly", "-bool", "true"])
            }
        }
    }
    @objc func revertRectangle() {
        let ids = installedRectangleIDs()
        guard !ids.isEmpty, confirm("Revert Rectangle config?", "This will quit \(ids.joined(separator: ", ")), delete screenEdgeGapLeft/Right/Top/Bottom and screenEdgeGapsOnMainScreenOnly, then relaunch it.") else { return }
        restartRectangle(ids: ids) { [weak self] in
            for id in ids { for k in PanelPosition.allCases.map(\.rectangleKey) + ["screenEdgeGapsOnMainScreenOnly"] { self?.runDefaults(["delete", id, k]) } }
        }
    }
}

// MARK: - main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
signal(SIGTERM, SIG_IGN)
let sigSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigSrc.setEventHandler { NSApp.terminate(nil) }
sigSrc.resume()
app.run()
