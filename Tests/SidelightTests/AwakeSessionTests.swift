import AppKit
import Foundation
import Testing

@testable import Sidelight
@testable import SidelightCore

struct AwakeSessionTests {
    /// Stands in for a power assertion: held while something keeps it.
    final class Token {
        let keepsDisplayOn: Bool
        let timeout: TimeInterval?

        init(keepsDisplayOn: Bool, timeout: TimeInterval?) {
            self.keepsDisplayOn = keepsDisplayOn
            self.timeout = timeout
        }
    }

    /// Every assertion made, weakly, to tell which are still held.
    final class Assertions {
        private var made: [() -> Token?] = []
        var refuses = false

        func make(_ keepsDisplayOn: Bool, _ timeout: TimeInterval?) -> AnyObject? {
            guard !refuses else { return nil }
            let token = Token(keepsDisplayOn: keepsDisplayOn, timeout: timeout)
            made.append { [weak token] in token }
            return token
        }

        var held: [Token] { made.compactMap { $0() } }
    }

    let assertions = Assertions()
    let workspace = NotificationCenter()
    let now = Date(timeIntervalSinceReferenceDate: 60 * 30_000_000)

    func session() -> AwakeSession {
        AwakeSession(makeAssertion: assertions.make, workspace: workspace)
    }

    @Test func `starting holds one assertion that macOS drops a minute after the end`() throws {
        let session = session()
        session.start(.minutes(15), now: now)
        #expect(session.state == .timed(started: now, ends: now.addingTimeInterval(15 * 60)))
        let token = try #require(assertions.held.first)
        #expect(assertions.held.count == 1)
        #expect(!token.keepsDisplayOn && token.timeout == 16 * 60)
    }

    @Test func `stopping lets go, and stopping again is fine`() {
        let session = session()
        session.start(.indefinitely, now: now)
        session.stop()
        #expect(session.state == .off && assertions.held.isEmpty)
        session.stop()
        #expect(session.state == .off)
    }

    @Test func `starting again replaces the session`() throws {
        let session = session()
        session.start(.minutes(15), now: now)
        session.start(.minutes(60), now: now)
        #expect(session.state.ends == now.addingTimeInterval(60 * 60))
        #expect(assertions.held.count == 1)
        #expect(try #require(assertions.held.first).timeout == 61 * 60)
    }

    @Test func `an indefinite session has no timeout`() throws {
        let session = session()
        session.start(.indefinitely, now: now)
        #expect(session.state == .indefinite)
        #expect(try #require(assertions.held.first).timeout == nil)
    }

    @Test func `keeping the display on swaps the assertion, keeping the end`() throws {
        let session = session()
        session.start(.minutes(30), now: now)
        let ends = session.state.ends
        session.keepsDisplayOn = true
        #expect(session.state.ends == ends)
        #expect(assertions.held.count == 1)
        #expect(try #require(assertions.held.first).keepsDisplayOn)
    }

    @Test func `keeping the display on while off holds nothing until started`() throws {
        let session = session()
        session.keepsDisplayOn = true
        #expect(assertions.held.isEmpty && session.state == .off)
        session.start(.indefinitely, now: now)
        #expect(try #require(assertions.held.first).keepsDisplayOn)
    }

    @Test func `a refused assertion changes nothing`() {
        let session = session()
        assertions.refuses = true
        session.start(.minutes(15), now: now)
        #expect(session.state == .off)

        assertions.refuses = false
        session.start(.indefinitely, now: now)
        assertions.refuses = true
        session.start(.minutes(15), now: now)
        session.keepsDisplayOn = true
        #expect(session.state == .indefinite && !session.displayHeld)
        #expect(assertions.held.count == 1 && assertions.held.first?.keepsDisplayOn == false)

        assertions.refuses = false
        session.keepsDisplayOn = false
        session.keepsDisplayOn = true
        #expect(session.displayHeld)
        session.stop()
        #expect(!session.displayHeld)
    }

    @Test func `a timed session stops itself at the end`() async {
        let session = session()
        session.start(until: .now.addingTimeInterval(0.05))
        #expect(session.state.isActive)
        #expect(await eventually { session.state == .off })
        #expect(assertions.held.isEmpty)
    }

    @Test func `sleeping ends the session`() async {
        let session = session()
        session.start(.indefinitely, now: now)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(await eventually { session.state == .off })
        #expect(assertions.held.isEmpty)
    }
}
