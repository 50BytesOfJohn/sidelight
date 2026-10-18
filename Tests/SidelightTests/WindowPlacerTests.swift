import AppKit
import SidelightCore
import Testing

@testable import Sidelight

/// The one registry, exercised through one of Sidelight's own windows: it takes a whole frame at once, so no
/// Accessibility access is needed to see what the records say.
@MainActor
struct WindowPlacerTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func display(panel: CGRect? = nil, padding: CGFloat = 8) -> DisplayArea {
        let reservations = panel.map { [Reservation(frame: $0, edge: .left, role: .main)] } ?? []
        return DisplayArea(
            id: "screen", frame: screen, cocoaFrame: screen, visibleFrame: screen,
            workArea: WorkArea(visibleFrame: screen, reservations: reservations, padding: padding),
            isPortrait: false)
    }

    /// `defer: true` so no window device is ever made: these windows are never shown, and a test that fills the
    /// registry makes dozens of them.
    private func window() -> (ManagedWindow, NSWindow) {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 600, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.minSize = CGSize(width: 50, height: 50)
        return (.own(OwnWindow(window: window)), window)
    }

    @Test func `a run of tiles keeps the frame from before the first of them`() throws {
        let placer = WindowPlacer()
        let (managed, window) = self.window()
        let original = try #require(managed.frame)
        let area = display()

        let half = CGRect(x: 8, y: 8, width: 700, height: 884)
        let first = try #require(
            placer.place(managed, at: half, intent: .manager(.leftHalf, step: 0), on: area, reason: "test"))
        #expect(placer.baseline(of: managed) == original)
        #expect(placer.isPlacedOnPurpose(managed, at: first))

        // Pressed again: a third of the width, still from the same original.
        let third = CGRect(x: 8, y: 8, width: 466, height: 884)
        let second = try #require(
            placer.place(managed, at: third, intent: .manager(.leftHalf, step: 1), on: area, reason: "test"))
        #expect(placer.baseline(of: managed) == original)
        #expect(placer.isPlacedOnPurpose(managed, at: second))

        // Moved by hand since: the next placement starts over from where the window actually is.
        window.setFrame(CGRect(x: 300, y: 300, width: 500, height: 300), display: false)
        let moved = try #require(managed.frame)
        #expect(!placer.isPlacedOnPurpose(managed, at: moved))
        _ = placer.place(managed, at: half, intent: .manager(.leftHalf, step: 0), on: area, reason: "test")
        #expect(placer.baseline(of: managed) == moved)

        // Put back, and forgotten: there's nothing left to put back.
        placer.forget(managed)
        #expect(placer.baseline(of: managed) == nil)
    }

    @Test func `avoidance alone leaves nothing for restore to put back`() throws {
        let placer = WindowPlacer()
        let (managed, _) = self.window()
        let area = display(panel: CGRect(x: 0, y: 0, width: 200, height: 900))
        let pushed = try #require(
            placer.place(
                managed, at: CGRect(x: 208, y: 100, width: 600, height: 400), intent: .avoidance(.keepClear),
                on: area, reason: "test"))
        // A window the panels pushed is put back by the panels, not by a window manager shortcut.
        #expect(placer.baseline(of: managed) == nil)
        #expect(!placer.isPlacedOnPurpose(managed, at: pushed))
    }

    @Test func `a deliberate placement drops what avoidance could put back`() throws {
        let placer = WindowPlacer()
        let (managed, _) = self.window()
        let area = display(panel: CGRect(x: 0, y: 0, width: 200, height: 900))
        let pushed = try #require(
            placer.place(
                managed, at: CGRect(x: 208, y: 100, width: 600, height: 400), intent: .avoidance(.keepClear),
                on: area, reason: "test"))
        placer.setAvoidanceBaselines(
            WindowBaselines(main: CGRect(x: 0, y: 100, width: 600, height: 400), accepted: pushed), of: managed,
            at: pushed, on: area)
        #expect(placer.avoidanceBaselines(of: managed, on: area) != nil)

        // The manager places it where avoidance had already left it: the row isn't deleted by anyone, it just
        // stops being avoidance's.
        _ = placer.place(
            managed, at: pushed, intent: .manager(.leftHalf, step: 0), on: area, reason: "test")
        #expect(placer.avoidanceBaselines(of: managed, on: area) == nil)
        #expect(placer.baseline(of: managed) != nil)
    }

    @Test func `switching the manager off forgets its baselines but not avoidance's`() throws {
        let placer = WindowPlacer()
        let (tiled, _) = window()
        let (pushed, _) = window()
        let area = display(panel: CGRect(x: 0, y: 0, width: 200, height: 900))
        let tile = CGRect(x: 208, y: 8, width: 700, height: 884)
        _ = placer.place(tiled, at: tile, intent: .manager(.leftHalf, step: 0), on: area, reason: "test")
        let moved = try #require(
            placer.place(
                pushed, at: CGRect(x: 208, y: 100, width: 600, height: 400), intent: .avoidance(.keepClear),
                on: area, reason: "test"))
        placer.setAvoidanceBaselines(
            WindowBaselines(main: CGRect(x: 0, y: 100, width: 600, height: 400), accepted: moved), of: pushed,
            at: moved, on: area)

        placer.forgetDeliberatePlacements()
        #expect(placer.baseline(of: tiled) == nil)
        #expect(placer.avoidanceBaselines(of: pushed, on: area) != nil)
    }

    /// A window avoidance looked at and left where it is can still gain a way back — a returning bar keeps its
    /// strip clear — so noting that has to record a window nothing has placed yet.
    @Test func `a window avoidance only looked at can still gain a way back`() throws {
        let placer = WindowPlacer()
        let (managed, _) = self.window()
        let area = display(panel: CGRect(x: 0, y: 0, width: 200, height: 900))
        let frame = try #require(managed.frame)
        #expect(placer.avoidanceBaselines(of: managed, on: area) == nil)
        placer.setAvoidanceBaselines(
            WindowBaselines(main: CGRect(x: 0, y: 100, width: 600, height: 400), accepted: frame), of: managed,
            at: frame, on: area)
        #expect(placer.avoidanceBaselines(of: managed, on: area) != nil)
        // Nothing placed it on purpose, so a window manager shortcut still has nothing to put back.
        #expect(placer.baseline(of: managed) == nil)
        #expect(!placer.isPlacedOnPurpose(managed, at: frame))
        // And nothing to remember is not a record.
        placer.forget(managed)
        placer.setAvoidanceBaselines(nil, of: managed, at: frame, on: area)
        #expect(placer.avoidanceBaselines(of: managed, on: area) == nil)
    }

    @Test func `what avoidance may put back on a display that changed shape is dropped`() throws {
        let placer = WindowPlacer()
        let (managed, _) = self.window()
        let area = display(panel: CGRect(x: 0, y: 0, width: 200, height: 900))
        let moved = try #require(
            placer.place(
                managed, at: CGRect(x: 208, y: 100, width: 600, height: 400), intent: .avoidance(.keepClear),
                on: area, reason: "test"))
        placer.setAvoidanceBaselines(
            WindowBaselines(main: CGRect(x: 0, y: 100, width: 600, height: 400), accepted: moved), of: managed,
            at: moved, on: area)
        placer.forgetAvoidanceOnStaleDisplays(among: [])
        #expect(placer.avoidanceBaselines(of: managed, on: area) == nil)
    }

    /// Sending a tile to another display is a placement like any other, so Restore still reaches the frame from
    /// before the first shortcut — not the tile the window had on the display it came from.
    @Test func `a move to another display keeps the frame from before the first tile`() throws {
        let placer = WindowPlacer()
        let (managed, _) = self.window()
        let original = try #require(managed.frame)
        let a = display()
        let b = DisplayArea(
            id: "second", frame: screen.offsetBy(dx: 1440, dy: 0), cocoaFrame: screen.offsetBy(dx: 1440, dy: 0),
            visibleFrame: screen.offsetBy(dx: 1440, dy: 0),
            workArea: WorkArea(visibleFrame: screen.offsetBy(dx: 1440, dy: 0), reservations: [], padding: 8),
            isPortrait: false)

        let tile = CGRect(x: 8, y: 8, width: 700, height: 884)
        _ = try #require(placer.place(managed, at: tile, intent: .manager(.leftHalf, step: 0), on: a, reason: "t"))
        #expect(placer.baseline(of: managed) == original)

        // Next Display: the same tile over there, and still the same frame to put it back to.
        let there = tile.offsetBy(dx: 1440, dy: 0)
        _ = try #require(
            placer.place(managed, at: there, intent: .manager(.leftHalf, step: 0), on: b, reason: "t"))
        #expect(placer.baseline(of: managed) == original)
        // And again, back to the first display.
        _ = try #require(placer.place(managed, at: tile, intent: .manager(.leftHalf, step: 0), on: a, reason: "t"))
        #expect(placer.baseline(of: managed) == original)
        // What avoidance may put back is still only read on the display it was taken on.
        #expect(placer.avoidanceBaselines(of: managed, on: b) == nil)
    }

    /// The registry holds both kinds of memory, and the two aren't worth the same. What avoidance may put back is
    /// what hiding a panel needs, and the window waiting for it may have been pushed long before anyone reached
    /// for a shortcut; where the manager would put a window back is a convenience for one press. So filling the
    /// registry drops the emptiest records first, then manager history, and a way back last of all.
    ///
    /// Narrowing the limit rather than making 65 windows: the policy is what's under test, not the number.
    @Test func `filling the registry drops the emptiest records before any way back`() throws {
        #expect(WindowPlacer.defaultLimit == 64)
        let placer = WindowPlacer(limit: 3)
        let area = display(panel: CGRect(x: 0, y: 0, width: 200, height: 900))
        let tile = CGRect(x: 208, y: 8, width: 700, height: 884)

        // A window avoidance pushed, with a way home for when the panel hides.
        let pushed = other(pid: 101)
        let home = CGRect(x: 0, y: 100, width: 600, height: 400)
        let moved = CGRect(x: 208, y: 100, width: 600, height: 400)
        placer.setAvoidanceBaselines(
            WindowBaselines(main: home, accepted: moved), of: pushed, at: moved, on: area)

        // And a window the manager tiled, with a frame to put it back to.
        let (tiled, _) = window()
        _ = try #require(placer.place(tiled, at: tile, intent: .manager(.leftHalf, step: 0), on: area, reason: "t"))
        let original = try #require(placer.baseline(of: tiled))

        // Two windows avoidance moved and has since given up on, then one more tile: over the limit, and it's the
        // two with nothing left to put back that go.
        for pid in [102, 103] as [pid_t] {
            let empty = other(pid: pid)
            placer.setAvoidanceBaselines(WindowBaselines(accepted: moved), of: empty, at: moved, on: area)
            placer.setAvoidanceBaselines(nil, of: empty, at: moved, on: area)
        }
        let tiles = fill(1, on: placer, at: tile, in: area)
        #expect(placer.avoidanceBaselines(of: pushed, on: area)?.main == home)
        #expect(placer.baseline(of: tiled) == original)
        #expect(placer.isPlacedOnPurpose(tiled, at: try #require(tiled.frame)))

        // More tiles, and now manager history has to give: the oldest restore frame goes, the way back stays.
        let more = fill(2, on: placer, at: tile, in: area)
        #expect(placer.avoidanceBaselines(of: pushed, on: area)?.main == home)
        #expect(placer.baseline(of: tiled) == nil)
        #expect(tiles.count + more.count == 3)
    }

    /// Another app's window, by identity alone: enough for everything the registry does with one.
    private func other(pid: pid_t) -> ManagedWindow {
        .other(AccessibilityElement.application(pid), pid: pid, launchDate: Date(timeIntervalSince1970: 1_000))
    }

    /// Tiles `count` windows nobody will ask about again. The windows are returned so they stay alive: the
    /// registry holds Sidelight's own windows weakly.
    private func fill(_ count: Int, on placer: WindowPlacer, at frame: CGRect, in area: DisplayArea) -> [NSWindow] {
        (0..<count).map { _ in
            let (other, strong) = window()
            placer.place(other, at: frame, intent: .manager(.rightHalf, step: 0), on: area, reason: "t")
            return strong
        }
    }

    /// Process identifiers are handed out again: a window of a later process with the same one isn't the window the
    /// registry remembers, however much the Accessibility element looks alike.
    @Test func `a process identifier reused by a later process matches nothing`() {
        let element = AccessibilityElement.application(4242)
        let launched = Date(timeIntervalSince1970: 1_000)
        let first = ManagedWindow.other(element, pid: 4242, launchDate: launched)
        #expect(first.isSame(as: .other(element, pid: 4242, launchDate: launched)))
        #expect(!first.isSame(as: .other(element, pid: 4242, launchDate: launched.addingTimeInterval(60))))
        #expect(!first.isSame(as: .other(element, pid: 99, launchDate: launched)))
        #expect(!first.isSame(as: .own(OwnWindow(window: nil))))
    }

    /// Only the window the manager asked for, never one of Sidelight's own windows that has closed since.
    @Test func `a closed window of Sidelight's own is never mistaken for another`() {
        let closed = ManagedWindow.own(OwnWindow(window: nil))
        #expect(!closed.isSame(as: .own(OwnWindow(window: nil))))
        #expect(!closed.exists)
    }
}
