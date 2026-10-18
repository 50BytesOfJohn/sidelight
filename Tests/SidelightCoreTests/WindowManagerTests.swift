import CoreGraphics
import Foundation
import Testing

@testable import SidelightCore

struct WindowLayoutTests {
    // A 1000×800 screen with a 20 pt menu bar.
    let visible = CGRect(x: 0, y: 20, width: 1000, height: 780)

    @Test(arguments: WindowAction.allCases.filter { $0.unitRect() != nil }, [0, 8])
    func `every tile stays inside the work area`(action: WindowAction, gap: CGFloat) throws {
        let area = WorkArea(visibleFrame: visible, reservations: [], padding: 8).rect
        for step in 0..<3 {
            let frame = try #require(WindowLayout.frame(for: action, step: step, in: area, gap: gap))
            #expect(area.contains(frame), "\(action) step \(step): \(frame)")
            #expect(frame.width > 0 && frame.height > 0)
        }
    }

    @Test func `padding insets every edge, and maximize fills what's left`() throws {
        let area = WorkArea(visibleFrame: visible, reservations: [], padding: 8).rect
        #expect(area == CGRect(x: 8, y: 28, width: 984, height: 764))
        #expect(WindowLayout.frame(for: .maximize, in: area, gap: 8) == area)
    }

    @Test(arguments: [0, 7, 8])
    func `complementary tiles share one boundary, exactly a gap apart`(gap: CGFloat) throws {
        // An odd width, so a half doesn't fall on a whole point.
        let area = CGRect(x: 3, y: 20, width: 1001, height: 777)
        let pairs: [(WindowAction, WindowAction)] = [
            (.leftHalf, .rightHalf), (.topLeft, .topRight), (.firstThird, .centerThird), (.centerThird, .lastThird),
            (.firstTwoThirds, .lastThird), (.firstThird, .lastTwoThirds),
        ]
        for (first, second) in pairs {
            let a = try #require(WindowLayout.frame(for: first, in: area, gap: gap))
            let b = try #require(WindowLayout.frame(for: second, in: area, gap: gap))
            #expect(b.minX - a.maxX == gap, "\(first) and \(second)")
            #expect(a.minX.rounded() == a.minX && b.maxX.rounded() == b.maxX)
        }
        let top = try #require(WindowLayout.frame(for: .topHalf, in: area, gap: gap))
        let bottom = try #require(WindowLayout.frame(for: .bottomHalf, in: area, gap: gap))
        #expect(bottom.minY - top.maxY == gap)
        #expect(top.minY == area.minY && bottom.maxY == area.maxY)
    }

    @Test func `halves cycle through a third and two thirds`() throws {
        let area = CGRect(x: 0, y: 0, width: 900, height: 600)
        #expect(WindowLayout.frame(for: .leftHalf, step: 0, in: area, gap: 0)?.width == 450)
        #expect(WindowLayout.frame(for: .leftHalf, step: 1, in: area, gap: 0)?.width == 300)
        #expect(WindowLayout.frame(for: .leftHalf, step: 2, in: area, gap: 0)?.width == 600)
        #expect(
            WindowLayout.frame(for: .rightHalf, step: 1, in: area, gap: 0)
                == CGRect(x: 600, y: 0, width: 300, height: 600))
        #expect(
            WindowLayout.frame(for: .bottomHalf, step: 2, in: area, gap: 0)
                == CGRect(x: 0, y: 200, width: 900, height: 400))
    }

    @Test func `thirds run top to bottom on a portrait display`() throws {
        let area = CGRect(x: 0, y: 0, width: 600, height: 900)
        let first = try #require(WindowLayout.frame(for: .firstThird, in: area, gap: 0, isPortrait: true))
        #expect(first == CGRect(x: 0, y: 0, width: 600, height: 300))
        let last = try #require(WindowLayout.frame(for: .lastTwoThirds, in: area, gap: 0, isPortrait: true))
        #expect(last == CGRect(x: 0, y: 300, width: 600, height: 600))
        // Halves still follow their arrow.
        #expect(WindowLayout.frame(for: .leftHalf, in: area, gap: 0, isPortrait: true)?.width == 300)
    }

    @Test(arguments: PanelPosition.allCases)
    func `the panel's strip is cut off with the avoidance gap beside it`(edge: PanelPosition) {
        let panel: CGRect =
            switch edge {
            case .left: CGRect(x: 0, y: 20, width: 300, height: 780)
            case .right: CGRect(x: 700, y: 20, width: 300, height: 780)
            case .top: CGRect(x: 0, y: 20, width: 1000, height: 60)
            case .bottom: CGRect(x: 0, y: 740, width: 1000, height: 60)
            }
        let area = WorkArea(
            visibleFrame: visible, reservations: [Reservation(frame: panel, edge: edge, role: .main)], padding: 4
        ).rect
        let expected: CGRect =
            switch edge {
            case .left: CGRect(x: 308, y: 24, width: 688, height: 772)
            case .right: CGRect(x: 4, y: 24, width: 688, height: 772)
            case .top: CGRect(x: 4, y: 88, width: 992, height: 708)
            case .bottom: CGRect(x: 4, y: 24, width: 992, height: 708)
            }
        #expect(area == expected)
    }

    @Test func `a details panel's strip counts like the panel's`() {
        let details = CGRect(x: 0, y: 20, width: 420, height: 780)
        let area = WorkArea(
            visibleFrame: visible, reservations: [Reservation(frame: details, edge: .left, role: .details)],
            padding: 8
        ).rect
        #expect(area.minX == 428)
    }

    @Test func `a window too big for its tile keeps the tile's anchored edges, inside the area`() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let left = CGRect(x: 0, y: 0, width: 496, height: 800)
        #expect(
            WindowLayout.anchored(CGSize(width: 600, height: 800), for: .leftHalf, tile: left, in: .unreserved(area))
                == CGRect(x: 0, y: 0, width: 600, height: 800))
        let right = CGRect(x: 504, y: 0, width: 496, height: 800)
        #expect(
            WindowLayout.anchored(CGSize(width: 600, height: 800), for: .rightHalf, tile: right, in: .unreserved(area))
                == CGRect(x: 400, y: 0, width: 600, height: 800))
        let topRight = CGRect(x: 504, y: 0, width: 496, height: 396)
        #expect(
            WindowLayout.anchored(
                CGSize(width: 600, height: 500), for: .topRight, tile: topRight, in: .unreserved(area))
                == CGRect(x: 400, y: 0, width: 600, height: 500))
        let bottomLeft = CGRect(x: 0, y: 404, width: 496, height: 396)
        #expect(
            WindowLayout.anchored(
                CGSize(width: 300, height: 500), for: .bottomLeft, tile: bottomLeft, in: .unreserved(area))
                == CGRect(x: 0, y: 300, width: 300, height: 500))
        // Centred along both axes, and moved back inside.
        let third = CGRect(x: 336, y: 0, width: 328, height: 800)
        #expect(
            WindowLayout.anchored(
                CGSize(width: 400, height: 600), for: .centerThird, tile: third, in: .unreserved(area))
                == CGRect(x: 300, y: 100, width: 400, height: 600))
        #expect(
            WindowLayout.anchored(CGSize(width: 1200, height: 600), for: .center, tile: area, in: .unreserved(area))
                .minX == 0)
    }

    @Test func `a constrained third on a portrait display keeps its bottom edge, centred across`() throws {
        let area = CGRect(x: 0, y: 0, width: 600, height: 900)
        let tile = try #require(WindowLayout.frame(for: .lastThird, in: area, gap: 0, isPortrait: true))
        #expect(tile == CGRect(x: 0, y: 600, width: 600, height: 300))
        #expect(
            WindowLayout.anchored(
                CGSize(width: 500, height: 200), for: .lastThird, tile: tile, in: .unreserved(area), isPortrait: true)
                == CGRect(x: 50, y: 700, width: 500, height: 200))
    }

    @Test func `a size is held within a window's minimum and maximum`() {
        let minimum = CGSize(width: 700, height: 520)
        let maximum = CGSize(width: 1200, height: CGFloat.greatestFiniteMagnitude)
        #expect(
            WindowLayout.clampedSize(CGSize(width: 300, height: 200), minimum: minimum, maximum: maximum)
                == minimum)
        #expect(
            WindowLayout.clampedSize(CGSize(width: 1500, height: 900), minimum: minimum, maximum: maximum)
                == CGSize(width: 1200, height: 900))
        // A maximum below the minimum gives way to the minimum.
        #expect(
            WindowLayout.clampedSize(CGSize(width: 900, height: 600), minimum: minimum, maximum: .zero) == minimum)
    }

    @Test func `centring keeps the size, no bigger than the area`() {
        let area = CGRect(x: 100, y: 0, width: 1000, height: 800)
        #expect(
            WindowLayout.centered(CGSize(width: 400, height: 300), in: area)
                == CGRect(x: 400, y: 250, width: 400, height: 300))
        #expect(WindowLayout.centered(CGSize(width: 2000, height: 300), in: area).width == 1000)
    }

    @Test func `a window moves to another display in proportion, and fits`() {
        let source = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let target = CGRect(x: 1000, y: -200, width: 2000, height: 1000)
        let moved = WindowLayout.transfer(CGRect(x: 100, y: 80, width: 500, height: 400), from: source, to: target)
        #expect(moved == CGRect(x: 1200, y: -100, width: 1000, height: 500))
        let small = CGRect(x: 0, y: 0, width: 500, height: 400)
        let big = WindowLayout.transfer(CGRect(x: 600, y: 0, width: 400, height: 800), from: source, to: small)
        #expect(small.contains(big))
    }

    @Test func `displays go left to right, then top to bottom, and wrap`() {
        let displays = [
            CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: -1200, y: 0, width: 1200, height: 900),
            CGRect(x: 0, y: -900, width: 1000, height: 900), CGRect(x: 1000, y: 0, width: 800, height: 600),
        ]
        #expect(WindowLayout.displayOrder(displays) == [1, 2, 0, 3])
        #expect(WindowLayout.neighbor(of: 0, among: displays, forward: true) == 3)
        #expect(WindowLayout.neighbor(of: 3, among: displays, forward: true) == 1)
        #expect(WindowLayout.neighbor(of: 1, among: displays, forward: false) == 3)
        #expect(WindowLayout.neighbor(of: 0, among: [displays[0]], forward: true) == nil)
    }

    @Test func `a window is on the display holding most of it`() {
        let displays = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        #expect(WindowLayout.sourceDisplay(of: CGRect(x: 900, y: 0, width: 400, height: 300), among: displays) == 1)
        // A tie goes to the one holding its centre's point, then the first.
        #expect(WindowLayout.sourceDisplay(of: CGRect(x: 800, y: 0, width: 400, height: 300), among: displays) == 1)
        #expect(WindowLayout.sourceDisplay(of: CGRect(x: 5000, y: 0, width: 10, height: 10), among: displays) == 0)
    }
}

struct SizeCycleTests {
    let frame = CGRect(x: 0, y: 0, width: 500, height: 800)
    let start = ContinuousClock.now

    private func press(
        _ cycle: inout SizeCycle, _ action: WindowAction = .leftHalf, after delay: Duration, sameWindow: Bool = true,
        frame: CGRect? = nil, cycles: Bool = true
    ) -> Int {
        let now = start + delay
        let step = cycle.step(
            for: action, isSameWindow: sameWindow, frame: frame ?? self.frame, now: now, cycles: cycles)
        cycle.record(action, placement: (action, step), accepted: self.frame, now: now)
        return step
    }

    @Test func `pressing a half again goes a third, two thirds, then a half`() {
        var cycle = SizeCycle()
        let steps = [0, 300, 600, 900].map { press(&cycle, after: .milliseconds($0)) }
        #expect(steps == [0, 1, 2, 0])
    }

    @Test func `too late, another action, window or frame, or cycling off, start over`() {
        var cycle = SizeCycle()
        _ = press(&cycle, after: .zero)
        #expect(press(&cycle, after: .milliseconds(800)) == 0)
        _ = press(&cycle, after: .milliseconds(900))
        #expect(press(&cycle, .rightHalf, after: .milliseconds(1000)) == 0)
        #expect(press(&cycle, .rightHalf, after: .milliseconds(1100), sameWindow: false) == 0)
        #expect(press(&cycle, .rightHalf, after: .milliseconds(1200), frame: frame.offsetBy(dx: 40, dy: 0)) == 0)
        #expect(press(&cycle, .rightHalf, after: .milliseconds(1300), cycles: false) == 0)
        #expect(press(&cycle, .rightHalf, after: .milliseconds(1400)) == 1)
    }

    @Test func `the last placement is kept for the same, unmoved window`() throws {
        var cycle = SizeCycle()
        cycle.record(.leftHalf, placement: (.leftHalf, 2), accepted: frame, now: start)
        let placement = try #require(cycle.placement(isSameWindow: true, frame: frame))
        #expect(placement.action == .leftHalf && placement.step == 2)
        #expect(cycle.placement(isSameWindow: false, frame: frame) == nil)
        #expect(cycle.placement(isSameWindow: true, frame: frame.insetBy(dx: 20, dy: 0)) == nil)
    }
}

struct WindowManagerSettingsTests {
    private func settings(_ json: String) throws -> WindowManagerSettings {
        try JSONDecoder().decode(WindowManagerSettings.self, from: Data(json.utf8))
    }

    @Test func `the defaults are off, spaced 8 pt, cycling, with the Sidelight preset saved in full`() throws {
        let defaults = WindowManagerSettings()
        #expect(!defaults.isEnabled && defaults.gap == 8 && defaults.padding == 8 && defaults.cyclesSizes)
        #expect(defaults.shortcuts.count == WindowAction.allCases.count)
        #expect(defaults.preset == .sidelight)
        #expect(try settings("{}") == defaults)
    }

    @Test func `the configuration without the group loads the defaults`() throws {
        var file = try #require(try JSONSerialization.jsonObject(with: AppConfiguration().json()) as? [String: Any])
        file["windowManager"] = nil
        let loaded = try AppConfiguration(json: JSONSerialization.data(withJSONObject: file))
        #expect(loaded.windowManager == WindowManagerSettings())
        file["windowManager"] = "garbage"
        #expect(try AppConfiguration(json: JSONSerialization.data(withJSONObject: file)).windowManager == .init())
    }

    @Test func `shortcuts save as an object keyed by action, and round-trip`() throws {
        var edited = AppConfiguration()
        edited.windowManager.isEnabled = true
        edited.windowManager.gap = 0
        edited.windowManager[action: .center] = Hotkey(keyCode: 8, modifiers: [.command, .shift], key: "C")
        let json = try edited.json()
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let group = try #require(object["windowManager"] as? [String: Any])
        let shortcuts = try #require(group["shortcuts"] as? [String: Any])
        #expect(shortcuts["leftHalf"] != nil && shortcuts.count == WindowAction.allCases.count)
        #expect(try AppConfiguration(json: json) == edited)
    }

    @Test func `spacing outside what the settings offer is moved into range`() throws {
        let edited = try settings(#"{"gap": -5, "padding": 900}"#)
        #expect(edited.gap == 0 && edited.padding == 32)
    }

    @Test func `one unreadable or modifier-less shortcut falls back alone, and unknown actions are dropped`() throws {
        var file = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(WindowManagerSettings())) as? [String: Any])
        var shortcuts = try #require(file["shortcuts"] as? [String: Any])
        shortcuts["leftHalf"] = ["keyCode": "nope"]
        shortcuts["rightHalf"] = ["keyCode": 124, "modifiers": 512, "key": "→"]
        shortcuts["center"] = ["keyCode": 8, "modifiers": 256, "key": "C", "isEnabled": false]
        shortcuts["almostMaximize"] = ["keyCode": 36, "modifiers": 6144, "key": "↩"]
        file["shortcuts"] = shortcuts
        let loaded = try JSONDecoder().decode(
            WindowManagerSettings.self, from: JSONSerialization.data(withJSONObject: file))
        let preset = WindowManagerPreset.sidelight
        #expect(loaded[action: .leftHalf] == preset.binding(for: .leftHalf))
        #expect(loaded[action: .rightHalf] == preset.binding(for: .rightHalf))
        #expect(loaded[action: .center] == Hotkey(keyCode: 8, modifiers: [.command], key: "C", isEnabled: false))
        #expect(loaded.shortcuts.count == WindowAction.allCases.count)
    }

    @Test func `an action missing from saved shortcuts arrives switched off`() throws {
        let edited = try settings(
            #"{"shortcuts": {"leftHalf": {"keyCode": 0, "modifiers": 6144, "key": "A", "isEnabled": true}}}"#)
        #expect(edited[action: .leftHalf].keyCode == 0)
        #expect(edited[action: .maximize].isSameShortcut(as: WindowManagerPreset.sidelight.binding(for: .maximize)))
        #expect(!edited[action: .maximize].isEnabled)
    }

    @Test func `the preset in use is worked out from the shortcuts`() {
        for preset in WindowManagerPreset.allCases {
            var settings = WindowManagerSettings()
            settings.shortcuts = preset.shortcuts
            #expect(settings.preset == preset)
            settings[action: .firstThird].isEnabled.toggle()
            #expect(settings.preset == nil)
        }
    }

    @Test(arguments: WindowManagerPreset.allCases)
    func `a preset binds every action, with no clashes`(preset: WindowManagerPreset) {
        let shortcuts = preset.shortcuts
        #expect(shortcuts.count == WindowAction.allCases.count)
        #expect(shortcuts.values.allSatisfy { $0.isValid })
        let enabled = shortcuts.values.filter(\.isEnabled)
        for (index, hotkey) in enabled.enumerated() {
            #expect(!enabled[(index + 1)...].contains { $0.isSameShortcut(as: hotkey) }, "\(hotkey.displayString)")
        }
        // Not even a switched-off one takes Sidelight's own defaults.
        let own: [Hotkey] = [.defaultToggle, .defaultCloseDetails, .defaultStashCapture, .defaultStashClipboard]
        #expect(!shortcuts.values.contains { hotkey in own.contains { $0.isSameShortcut(as: hotkey) } })
    }

    @Test func `the Sidelight preset is Rectangle's keys with the explicit thirds off`() {
        let sidelight = WindowManagerPreset.sidelight.shortcuts
        let rectangle = WindowManagerPreset.rectangle.shortcuts
        for action in WindowAction.allCases {
            #expect(sidelight[action]?.isSameShortcut(as: rectangle[action]!) == true)
            let isThird = [.firstThird, .centerThird, .lastThird, .firstTwoThirds, .centerTwoThirds, .lastTwoThirds]
                .contains(action)
            #expect(sidelight[action]?.isEnabled == !isThird)
            #expect(rectangle[action]?.isEnabled == true)
        }
    }
}
