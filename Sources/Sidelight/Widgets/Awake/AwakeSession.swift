import AppKit
import Foundation
import IOKit.pwr_mgt
import Observation
import SidelightCore
import os

/// One IOKit power assertion, held for as long as this lives: macOS doesn't sleep on its own, nor dim the display
/// with `keepsDisplayOn`. `pmset -g assertions` lists it under Sidelight.
final class PowerAssertion {
    private let id: IOPMAssertionID

    /// `timeout` lets macOS drop the assertion itself, should Sidelight be stopped before it can; `nil` for none.
    init?(keepsDisplayOn: Bool, timeout: TimeInterval?) {
        // The display assertion keeps the system awake too, so one is ever held.
        let type = keepsDisplayOn ? kIOPMAssertPreventUserIdleDisplaySleep : kIOPMAssertPreventUserIdleSystemSleep
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithDescription(
            type as CFString, "Sidelight" as CFString, nil, "Keeping the Mac awake (Awake widget)" as CFString, nil,
            timeout ?? 0, kIOPMAssertionTimeoutActionRelease as CFString, &id)
        guard result == kIOReturnSuccess else {
            Log.awake.error("Couldn't keep the Mac awake: IOKit error \(result, privacy: .public)")
            return nil
        }
        self.id = id
    }

    deinit {
        IOPMAssertionRelease(id)
    }
}

/// Keeps the Mac awake for a while or until stopped, for every Awake widget. Held in memory only: nothing keeps the
/// Mac awake after Sidelight quits or relaunches. Sleeping anyway (the lid, the Apple menu) ends it.
@Observable
final class AwakeSession {
    /// Makes the assertion that keeps the Mac awake, the display too when asked: an object that holds it until
    /// released, or `nil` if macOS refused.
    typealias MakeAssertion = (_ keepsDisplayOn: Bool, _ timeout: TimeInterval?) -> AnyObject?

    private(set) var state = AwakeState.off
    /// Changing it while awake swaps the assertion for the other kind, keeping the same end.
    var keepsDisplayOn = false {
        didSet {
            if keepsDisplayOn != oldValue && state.isActive { reassert() }
        }
    }
    /// Whether the assertion held right now keeps the display on, which lags ``keepsDisplayOn`` if macOS refused it.
    private(set) var displayHeld = false

    @ObservationIgnored private let makeAssertion: MakeAssertion
    @ObservationIgnored private let workspace: NotificationCenter
    @ObservationIgnored private var assertion: AnyObject?
    @ObservationIgnored private let expiry = DelayedTask()
    @ObservationIgnored private var sleepObserver: (any NSObjectProtocol)?

    init(
        makeAssertion: @escaping MakeAssertion = { PowerAssertion(keepsDisplayOn: $0, timeout: $1) },
        workspace: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.makeAssertion = makeAssertion
        self.workspace = workspace
    }

    /// Starts a fresh session of `choice`, in place of any running one.
    func start(_ choice: AwakeChoice, now: Date = .now) {
        begin(.started(choice, at: now), now: now)
    }

    /// Starts a session ending at `ends`, which needn't be a whole minute.
    func start(until ends: Date, now: Date = .now) {
        begin(.timed(started: now, ends: ends), now: now)
    }

    /// Lets the Mac sleep as usual again. Safe to call when nothing is running.
    func stop() {
        assertion = nil
        displayHeld = false
        expiry.cancel()
        if let sleepObserver { workspace.removeObserver(sleepObserver) }
        sleepObserver = nil
        if state != .off { state = .off }
    }

    private func begin(_ newState: AwakeState, now: Date) {
        let remaining = newState.remaining(at: now)
        // A minute past the end, macOS drops the assertion itself if the expiry below never runs.
        // The assertion logs why it failed; the state stays as it was.
        guard let assertion = makeAssertion(keepsDisplayOn, remaining.map { $0 + 60 }) else { return }
        self.assertion = assertion
        displayHeld = keepsDisplayOn
        state = newState
        if let remaining {
            expiry.schedule(after: .seconds(remaining), tolerance: .seconds(1)) { [weak self] in self?.stop() }
        } else {
            expiry.cancel()
        }
        watchForSleep()
    }

    /// A new assertion of the kind ``keepsDisplayOn`` asks for, until the same end. The old one stays if macOS
    /// refuses the new one.
    private func reassert(now: Date = .now) {
        guard let assertion = makeAssertion(keepsDisplayOn, state.remaining(at: now).map { $0 + 60 }) else { return }
        self.assertion = assertion
        displayHeld = keepsDisplayOn
    }

    /// Sleeping anyway ends the session, so the Mac doesn't wake to it still running, or kept awake by surprise.
    private func watchForSleep() {
        guard sleepObserver == nil else { return }
        sleepObserver = workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }
}
