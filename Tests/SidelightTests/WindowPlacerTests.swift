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

    private func window() -> (ManagedWindow, NSWindow) {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 600, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
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
        #expect(placer.withAvoidanceBaselines.isEmpty)
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
        #expect(placer.withAvoidanceBaselines.isEmpty)
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
        #expect(placer.withAvoidanceBaselines.isEmpty)
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
