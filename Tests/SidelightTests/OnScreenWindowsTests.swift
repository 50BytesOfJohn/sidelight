import CoreGraphics
import Testing

@testable import Sidelight

struct OnScreenWindowsTests {
    let window = CGRect(x: 100, y: 100, width: 600, height: 400)
    let elsewhere = CGRect(x: 800, y: 100, width: 300, height: 300)

    @Test func `a shown window told apart from its siblings is on screen`() {
        let onScreen = OnScreenWindows(framesByProcess: [42: [window, elsewhere]])
        #expect(onScreen.contains(window, of: 42, siblings: [elsewhere]))
        // Within what apps round to.
        #expect(onScreen.contains(window.offsetBy(dx: 1, dy: -1), of: 42, siblings: [elsewhere]))
    }

    @Test func `a window not shown, or shown by another app, isn't`() {
        let onScreen = OnScreenWindows(framesByProcess: [42: [elsewhere], 7: [window]])
        #expect(!onScreen.contains(window, of: 42, siblings: []))
        #expect(!onScreen.contains(window, of: 99, siblings: []))
    }

    @Test func `a window whose sibling has its frame can't be told apart`() {
        let onScreen = OnScreenWindows(framesByProcess: [42: [window]])
        #expect(!onScreen.contains(window, of: 42, siblings: [window]))
    }

    @Test func `an unlisted window over the app's own still counts it as shown`() {
        // An overlay the app draws over its window, which Accessibility doesn't list.
        let onScreen = OnScreenWindows(framesByProcess: [42: [window, window]])
        #expect(onScreen.contains(window, of: 42, siblings: []))
    }

    @Test func `only apps with a window over a panel are worth asking`() {
        let panel = CGRect(x: 0, y: 25, width: 300, height: 875)
        let onScreen = OnScreenWindows(framesByProcess: [42: [elsewhere, window], 7: [elsewhere]])
        #expect(onScreen.processes(overlapping: [panel]) == [42])
        #expect(onScreen.processes(overlapping: []).isEmpty)
    }
}
