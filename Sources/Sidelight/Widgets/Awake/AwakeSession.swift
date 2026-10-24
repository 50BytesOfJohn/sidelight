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

/// Where the running session is kept between launches: a few bytes, written only as one starts or stops.
struct AwakeSessionFile {
    let url: URL

    /// The saved session, or off when there's none or it can't be read.
    func load() -> AwakeState {
        do {
            return try JSONDecoder().decode(AwakeState.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return .off
        } catch {
            Log.awake.error("Can't read the saved Awake session: \(error)")
            return .off
        }
    }

    func save(_ state: AwakeState) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        } catch {
            Log.awake.error("Can't save the Awake session: \(error)")
        }
    }
}

/// Keeps the Mac awake for a while or until stopped, for every Awake widget. The session is saved, so it carries on
/// after Sidelight relaunches, and it outlasts sleep: closing the lid or choosing Sleep sleeps the Mac anyway, and
/// on waking it's kept awake again for whatever time is left.
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
    @ObservationIgnored private let file: AwakeSessionFile?
    @ObservationIgnored private var assertion: AnyObject?
    @ObservationIgnored private let expiry = DelayedTask()
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    /// `file` keeps the session between launches; `nil` keeps it in memory only.
    init(
        makeAssertion: @escaping MakeAssertion = { PowerAssertion(keepsDisplayOn: $0, timeout: $1) },
        workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
        file: AwakeSessionFile? = nil
    ) {
        self.makeAssertion = makeAssertion
        self.workspace = workspace
        self.file = file
    }

    /// Picks up the session saved by the last launch, if it's still running: an indefinite one, or a timed one
    /// that hasn't ended meanwhile.
    func restore(now: Date = .now) {
        guard !state.isActive, let saved = file?.load(), saved.isActive else { return }
        let resumed = saved.resumed(at: now)
        if resumed.isActive {
            Log.awake.notice("Resuming the Awake session from the last launch")
            begin(resumed, now: now)
        } else {
            file?.save(.off)
        }
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
        letGo()
        guard state != .off else { return }
        state = .off
        file?.save(.off)
    }

    /// Lets go of the Mac as Sidelight quits, keeping the saved session for the next launch to pick up.
    func suspend() {
        letGo()
    }

    private func letGo() {
        assertion = nil
        displayHeld = false
        expiry.cancel()
        if let wakeObserver { workspace.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    private func begin(_ newState: AwakeState, now: Date) {
        let remaining = newState.remaining(at: now)
        // A minute past the end, macOS drops the assertion itself if the expiry below never runs.
        // The assertion logs why it failed; the state stays as it was.
        guard let assertion = makeAssertion(keepsDisplayOn, remaining.map { $0 + 60 }) else { return }
        self.assertion = assertion
        displayHeld = keepsDisplayOn
        if state != newState {
            state = newState
            file?.save(newState)
        }
        if let remaining {
            expiry.schedule(after: .seconds(remaining), tolerance: .seconds(1)) { [weak self] in self?.stop() }
        } else {
            expiry.cancel()
        }
        watchForWake()
    }

    /// A new assertion of the kind ``keepsDisplayOn`` asks for, until the same end. The old one stays if macOS
    /// refuses the new one.
    private func reassert(now: Date = .now) {
        guard let assertion = makeAssertion(keepsDisplayOn, state.remaining(at: now).map { $0 + 60 }) else { return }
        self.assertion = assertion
        displayHeld = keepsDisplayOn
    }

    /// Carries on after the Mac wakes: a timed session that ran out while it slept stops, and one that didn't is
    /// held again for the time left, as the expiry and the assertion's own timeout may have counted the sleep
    /// differently.
    func resumeAfterWake(now: Date = .now) {
        guard state.isActive else { return }
        if state.resumed(at: now).isActive {
            if state.ends != nil { begin(state, now: now) }
        } else {
            stop()
        }
    }

    private func watchForWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.resumeAfterWake() }
        }
    }
}
