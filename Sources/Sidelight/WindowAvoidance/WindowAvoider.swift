import AppKit
import ApplicationServices
import Observation
import SidelightCore
import os

/// The strip one display keeps clear, in Cocoa coordinates: its panel's, or the details panel's standing in for it.
struct PanelRegion: Equatable {
    var displayID: Display.ID
    var role: ReservationRole
    var frame: CGRect
    /// The visible frame and the whole frame of its display.
    var visibleFrame: CGRect
    var displayFrame: CGRect
    var edge: PanelPosition

    /// Whether the two keep the same strip clear, the same way.
    func reservesSame(as other: PanelRegion) -> Bool {
        role == other.role && edge == other.edge && frame.integral == other.frame.integral
    }
}

/// Keeps other apps' windows out from under the panels, using the Accessibility API.
///
/// Watches every regular app for window creation, moves, resizes and un-minimizing, and moves or shrinks any
/// standard window that ends up overlapping the panel (see ``AvoidanceGeometry``). An accessory app (a menu bar app)
/// is watched from when it first comes to the front, as it does to show a window. While the user is dragging, it
/// waits for mouse-up instead of fighting the drag.
///
/// Events alone miss windows: a window is often announced before the window server shows it, or before it's a
/// standard window, and one that then appears in place sends nothing more. So a window over a panel that can't be
/// moved yet is checked again a few times, a little later each time; and whenever windows could have turned up
/// unannounced (an app comes to the front or is unhidden, the Space changes, the screens wake) the windows on screen
/// are checked. Each check first asks the window server, in one call, which apps have a window over a panel at all,
/// so it usually asks no app anything.
///
/// It remembers where each window was before it moved it, so when a strip is released (the panels hide, or the
/// details panel gives way to the side panel again) windows nobody touched since go back. See
/// ``ReservationTransition`` for exactly what moves. That memory, and every frame it writes, belong to
/// ``WindowPlacer``: avoidance decides when and where, the placer how, and its registry says whether a window is
/// still avoidance's to put back or someone placed it on purpose.
///
/// It only ever moves a window it can be sure of: a standard window of an eligible app, on the active Space as the
/// window server lists it, and told apart from that app's other windows (see ``OnScreenWindows``). Anything less
/// certain is left alone. Every move, whether avoidance, putting back or following an edge, goes through that check.
///
/// With avoidance off it watches nothing, asks for nothing and remembers nothing, so it costs nothing.
@Observable
final class WindowAvoider {
    static let mouseUpPollInterval: Duration = .milliseconds(50)
    /// An app not ready for Accessibility yet is tried again after this, then twice as long each time up to the
    /// maximum, so a slow launch is still caught without asking a hung app often.
    static let registrationRetryDelay: Duration = .milliseconds(500)
    static let maximumRegistrationRetryDelay: Duration = .seconds(8)
    static let maximumRegistrationAttempts = 10
    /// A window over a panel that can't be moved yet (not shown yet, not a standard window yet, its frame unreadable)
    /// is checked again after each of these in turn, then left to its next event.
    static let recheckDelays: [Duration] = [
        .milliseconds(100), .milliseconds(300), .milliseconds(700), .milliseconds(1500), .seconds(3),
    ]
    /// After an app starts being watched, comes to the front or is unhidden, its windows are checked at once and once
    /// more after this: a window it had already created may only be shown by then, and being shown sends no event.
    static let followUpDelay: Duration = .seconds(1)
    /// After the Space changes or the screens wake, the window server takes a moment to list what's shown now.
    static let spaceChangeSettleDelay: Duration = .milliseconds(300)
    static let wakeSettleDelay: Duration = .seconds(1)

    @ObservationIgnored var mode: WindowAvoidanceMode = .smart {
        didSet {
            guard (mode == .off) != (oldValue == .off), isStarted else { return }
            if mode == .off { deactivate() } else { activate(promptingForAccess: false) }
        }
    }
    /// The strips to keep clear; empty while the panels are hidden.
    @ObservationIgnored var occupiedRegions: () -> [PanelRegion] = { [] }

    private struct PendingWindow {
        let window: AccessibilityElement
        let eventDate: Date
        let reason: String
    }

    /// What one look at a window found.
    private enum Outcome {
        /// Not over a panel, or not a window that moves for one (minimized, full screen): nothing to do.
        case clear
        case moved
        /// Over a panel, but not certainly a window it may move yet: worth another look shortly.
        case unsure
    }

    /// Whose windows a check looks at.
    private enum CheckScope {
        case apps(Set<pid_t>)
        case all

        func contains(_ pid: pid_t) -> Bool {
            switch self {
            case .apps(let pids): pids.contains(pid)
            case .all: true
            }
        }

        func union(_ other: CheckScope) -> CheckScope {
            switch (self, other) {
            case (.apps(let pids), .apps(let others)): .apps(pids.union(others))
            default: .all
            }
        }
    }

    /// A check of the windows on screen, due at `deadline`.
    private struct PendingCheck {
        let deadline: ContinuousClock.Instant
        let scope: CheckScope
        let reason: String
        /// The app checked again for a window it couldn't move yet, if that's what this is.
        let recheck: pid_t?
    }

    @ObservationIgnored private var observers: [pid_t: AXObserver] = [:]
    @ObservationIgnored private var registrationAttempts: [pid_t: Int] = [:]
    /// Delayed registrations (fresh launches and retries), cancelled when avoidance turns off or the app quits.
    @ObservationIgnored private var pendingRegistrations: [pid_t: Task<Void, Never>] = [:]
    @ObservationIgnored private var windowsAwaitingMouseUp: [PendingWindow] = []
    @ObservationIgnored private var mouseUpTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceObservations: [NotificationCenter.ObservationToken] = []
    @ObservationIgnored private var isStarted = false
    /// The strips before a change that's waiting: for a panel to settle, or the mouse button to come up. Later
    /// changes keep this start and go to wherever things are by then, so a change undone meanwhile moves nothing,
    /// and a change replaced by another moves windows once.
    @ObservationIgnored private var pendingTransitionStart: [PanelRegion]?
    @ObservationIgnored private let settlingTransition = DelayedTask()
    /// Checks of the windows on screen still to come; those due together run as one.
    @ObservationIgnored private var pendingChecks: [PendingCheck] = []
    @ObservationIgnored private let nextCheck = DelayedTask()
    /// How many times in a row each app has been checked again for a window it couldn't move yet.
    @ObservationIgnored private var recheckAttempts: [pid_t: Int] = [:]

    private let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    /// Which apps' windows it may move, besides being apps with windows other than Sidelight.
    @ObservationIgnored private let includes: (NSRunningApplication) -> Bool
    @ObservationIgnored private let permission: AccessibilityPermission
    /// The only thing that writes a window frame, and the one registry of what Sidelight has placed.
    @ObservationIgnored private let placer: WindowPlacer

    /// - Parameter includes: Which apps' windows it may move: every app with windows, unless the app's composition
    ///   narrows it (to one disposable app, say, when trying window movement out).
    init(
        permission: AccessibilityPermission, placer: WindowPlacer,
        includes: @escaping (NSRunningApplication) -> Bool = { _ in true }
    ) {
        self.permission = permission
        self.placer = placer
        self.includes = includes
        permission.onChange { [weak self] in self?.trustChanged($0) }
    }

    /// Whether `application`'s windows may be moved: a regular app's, or an accessory app's (a menu bar app's
    /// settings window), other than Sidelight's. Background-only processes have no windows to move.
    private func isEligible(_ application: NSRunningApplication) -> Bool {
        application.activationPolicy != .prohibited && application.processIdentifier != ownProcessIdentifier
            && includes(application)
    }

    /// Whether `application` is watched from the start: every regular app. An accessory app is watched once it comes
    /// to the front; most never do, so they're never asked anything.
    private func isWatchedEagerly(_ application: NSRunningApplication) -> Bool {
        application.activationPolicy == .regular && isEligible(application)
    }

    /// Starts observing apps while ``mode`` isn't off. Without Accessibility access yet, waits for it.
    func start(promptingForAccess: Bool) {
        guard !isStarted else { return }
        isStarted = true
        AccessibilityElement.limitMessagingTimeout()
        if mode != .off { activate(promptingForAccess: promptingForAccess) }
    }

    /// Stops observing, and drops every pending change and what it remembered. Call before the app quits, after
    /// ``releaseAll()``.
    func stop() {
        guard isStarted else { return }
        deactivate()
        isStarted = false
    }

    /// Moves every overlapping window right now. Returns how many were moved.
    @discardableResult
    func avoidAllWindows() -> Int {
        let moved = check(.all, reason: "avoidAll")
        Log.avoidance.info("Moved \(moved) windows")
        return moved
    }

    // MARK: Reservation changes

    /// The strips to keep clear changed from `previous` to what ``occupiedRegions`` returns now, in one step: the
    /// details panel opened or closed, the panels were hidden or shown, or a panel moved or resized. Windows move once,
    /// straight to where they belong (see ``ReservationTransition``).
    ///
    /// - Parameter delay: How long to let things settle first, as while a panel animates to a new size or a slider
    ///   is dragged. Changes meanwhile are folded into one, from the first one's start. Without it the change applies
    ///   now, along with any still settling. Either way, it waits for the mouse button to come up.
    func reservationsChanged(from previous: [PanelRegion], settlingFor delay: Duration? = nil) {
        guard mode != .off, isStarted else { return }
        pendingTransitionStart = pendingTransitionStart ?? previous
        if let delay {
            settlingTransition.schedule(after: delay) { [weak self] in self?.applyPendingTransition() }
        } else {
            settlingTransition.cancel()
            applyPendingTransition()
        }
    }

    /// Puts back every window Sidelight moved and nobody touched since, as if the panels were hidden. Call before
    /// the app quits.
    func releaseAll() {
        settlingTransition.cancel()
        let start = pendingTransitionStart ?? occupiedRegions()
        pendingTransitionStart = nil
        guard mode != .off, isStarted else { return }
        applyTransition(from: start, to: [])
        placer.forgetAvoidance()
    }

    /// Applies the change waiting since ``pendingTransitionStart``, unless the mouse button is down: then once it's up.
    private func applyPendingTransition() {
        guard let start = pendingTransitionStart else { return }
        guard NSEvent.pressedMouseButtons == 0 else {
            waitForMouseUp()
            return
        }
        pendingTransitionStart = nil
        applyTransition(from: start, to: occupiedRegions())
    }

    private func applyTransition(from old: [PanelRegion], to new: [PanelRegion]) {
        let before = Dictionary(old.map { ($0.displayID, $0) }) { first, _ in first }
        let after = Dictionary(new.map { ($0.displayID, $0) }) { first, _ in first }
        let changed = Set(before.keys).union(after.keys).filter { id in
            switch (before[id], after[id]) {
            case (nil, nil): false
            case (let old?, let new?): !old.reservesSame(as: new)
            default: true
            }
        }
        guard !changed.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            // Tells this avoider too, which then forgets what it moved.
            permission.refresh()
            return
        }
        guard let screenHeight = ScreenLayout.primaryScreenHeight else { return }

        // Frames on a display that's gone or changed shape since can't be put back anywhere meaningful.
        let displays = Display.connected()
        placer.forgetAvoidanceOnStaleDisplays(among: displays)
        guard displays.contains(where: { changed.contains($0.id) }) else { return }
        let areas = ScreenLayout.areas(regions: new, among: displays)
        let onScreen = OnScreenWindows.current()

        var visited: [ManagedWindow] = []
        // The windows on each display whose strip changed, decided together: windows side by side move as one.
        var windowsByDisplay: [Display.ID: [(window: ManagedWindow, frame: CGRect, baselines: WindowBaselines?)]] =
            [:]
        // Every regular app, and the accessory apps being watched: no other app's windows were ever moved.
        let applications = NSWorkspace.shared.runningApplications.filter {
            isWatchedEagerly($0) || (observers[$0.processIdentifier] != nil && isEligible($0))
        }
        for application in applications {
            let pid = application.processIdentifier
            // An app whose windows can't all be listed can't have one told apart from the others: none moves, and
            // what was remembered of them is forgotten.
            guard let allWindows = AccessibilityElement.application(pid).readableWindows else { continue }
            let windows: [(window: AccessibilityElement, frame: CGRect)] = allWindows.compactMap { window in
                guard window.isStandardWindow, !window.isFullScreen, !window.isMinimized, let frame = window.frame
                else { return nil }
                return (window, frame)
            }
            for (element, frame) in windows {
                // The display holding most of it, if its strip changed.
                guard
                    let display = areas.max(by: { area(frame, $0.frame) < area(frame, $1.frame) }),
                    area(frame, display.frame) > 0, changed.contains(display.id)
                else { continue }
                let window = ManagedWindow.other(element, pid: pid, launchDate: application.launchDate)
                // Another Space, or not told apart from another window: never moved, and no longer put back.
                guard mayMove(element, frame: frame, of: application, among: allWindows, onScreen: onScreen) else {
                    continue
                }
                visited.append(window)
                windowsByDisplay[display.id, default: []].append(
                    (window, frame, placer.avoidanceBaselines(of: window, on: display)))
            }
        }

        var counts: [WindowMoveReason: Int] = [:]
        for display in areas {
            let id = display.id
            guard let windows = windowsByDisplay[id] else { continue }
            let from = before[id].map { $0.reservation(primaryScreenHeight: screenHeight) }
            let to = after[id].map { $0.reservation(primaryScreenHeight: screenHeight) }
            let decisions = ReservationTransition.decide(
                windows.map {
                    ReservationTransition.Candidate(
                        frame: $0.frame, baselines: $0.baselines,
                        isPlacedOnPurpose: placer.isPlacedOnPurpose($0.window, at: $0.frame))
                },
                from: from, to: to, visibleFrame: display.visibleFrame, displayFrame: display.frame, mode: mode)

            for (entry, decision) in zip(windows, decisions) {
                switch decision {
                case .leave(let baselines):
                    placer.setAvoidanceBaselines(baselines, of: entry.window, at: entry.frame, on: display)
                case .move(let move):
                    let axis = move.reason == .follow ? before[id]?.edge : after[id]?.edge
                    perform(
                        move, on: entry.window, from: entry.frame, axis: axis ?? .left, clearOf: to, on: display,
                        previous: entry.baselines)
                    counts[move.reason, default: 0] += 1
                }
            }
        }
        // Windows remembered on these displays and not found (closed, minimized, full screen, their app quit) have
        // nowhere to go back to; those on other displays keep what they had.
        placer.forgetAvoidance(onDisplays: changed, except: { window in visited.contains { $0.isSame(as: window) } })
        let summary = counts.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " ")
        Log.avoidance.info("Reservations changed on \(changed.count) displays: \(summary, privacy: .public)")
    }

    /// Moves `window` as `move` says, and notes what avoidance may put back afterwards: a move refused outright
    /// leaves whatever way back the window already had, and one that happened leaves the move's own.
    private func perform(
        _ move: ReservationTransition.Move, on window: ManagedWindow, from frame: CGRect, axis: PanelPosition,
        clearOf reservation: Reservation?, on display: DisplayArea, previous: WindowBaselines?
    ) {
        // Gone meanwhile.
        guard
            let accepted = placer.place(
                window, at: move.frame, fallback: move.fallback.map { (frame: $0, axis: axis) },
                intent: .avoidance(move.reason), on: display, clearOf: reservation, reason: move.reason.rawValue)
        else { return }
        // Refused outright: nothing moved, so there's nothing new to put back.
        guard !WindowFrames.isUnchanged(accepted, since: frame) else {
            let kept = previous.flatMap { WindowFrames.isUnchanged(frame, since: $0.accepted) ? $0 : nil }
            placer.setAvoidanceBaselines(kept, of: window, at: frame, on: display)
            return
        }
        Log.avoidance.debug(
            """
            \(move.reason.rawValue, privacy: .public) from=\(NSStringFromRect(frame), privacy: .public) \
            to=\(NSStringFromRect(accepted), privacy: .public)
            """
        )
        placer.setAvoidanceBaselines(move.baselines(accepted: accepted), of: window, at: accepted, on: display)
    }

    /// Notes what avoidance may put back after it moved `window` from `before` to `accepted`, to keep a strip of
    /// `role` clear.
    ///
    /// A window still where Sidelight last left it keeps the baselines it had, with the new accepted frame. Otherwise
    /// it starts over, and only the side panel or bar gives it a way back: hiding the panels puts back what they
    /// pushed. The details panel's way back belongs to the windows it took the space from when it opened (see
    /// ``ReservationTransition``). A window it pushes later, opened or moved since, has no frame from before the
    /// session to return to; it can still follow the edge it's left touching when the details panel closes.
    private func remember(
        _ window: ManagedWindow, before: CGRect, accepted: CGRect, role: ReservationRole,
        previous: WindowBaselines?, on display: DisplayArea?
    ) {
        guard !WindowFrames.isUnchanged(accepted, since: before) else { return }
        var baselines =
            previous.flatMap { WindowFrames.isUnchanged(before, since: $0.accepted) ? $0 : nil }
            ?? WindowBaselines(accepted: accepted)
        if role == .main { baselines.main = baselines.main ?? before }
        baselines.accepted = accepted
        // Nothing to put back: nothing to remember.
        let hasWayBack = baselines.main != nil || baselines.details != nil
        placer.setAvoidanceBaselines(hasWayBack ? baselines : nil, of: window, at: accepted, on: display)
    }

    /// Access granted: windows are kept clear afresh. Revoked: nothing can move, so it forgets what was moved and
    /// stops watching until access comes back.
    private func trustChanged(_ isTrusted: Bool) {
        guard mode != .off, isStarted else { return }
        if isTrusted { return registerAllApplications() }
        Log.avoidance.notice("Accessibility access was revoked; forgetting moved windows")
        placer.forgetAvoidance()
        pendingTransitionStart = nil
        settlingTransition.cancel()
        windowsAwaitingMouseUp = []
        cancelChecks()
        for pid in Array(observers.keys) { unregister(pid) }
        registrationAttempts = [:]
    }

    // MARK: Observation

    private func activate(promptingForAccess: Bool) {
        permission.setNeeded(true, by: .avoidance)
        let wasTrusted = permission.isTrusted
        if permission.check(prompting: promptingForAccess) {
            // Access that's only now noticed reached ``trustChanged(_:)``, which registered already.
            if wasTrusted { registerAllApplications() }
        } else {
            Log.avoidance.info("Accessibility access not granted yet; waiting for it")
        }
        observeWorkspace()
    }

    private func deactivate() {
        permission.setNeeded(false, by: .avoidance)
        mouseUpTask?.cancel()
        mouseUpTask = nil
        windowsAwaitingMouseUp = []
        pendingTransitionStart = nil
        settlingTransition.cancel()
        cancelChecks()
        placer.forgetAvoidance()
        for task in pendingRegistrations.values { task.cancel() }
        pendingRegistrations = [:]
        for token in workspaceObservations { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceObservations = []
        for pid in Array(observers.keys) { unregister(pid) }
        registrationAttempts = [:]
        Log.avoidance.info("Stopped observing windows")
    }

    private func observeWorkspace() {
        guard workspaceObservations.isEmpty else { return }
        let workspace = NSWorkspace.shared
        let center = workspace.notificationCenter
        workspaceObservations = [
            center.addObserver(of: workspace, for: .didLaunchApplication) { [weak self] message in
                let application = message.application
                guard let self, isWatchedEagerly(application) else { return }
                // Freshly launched apps usually aren't Accessibility-ready for a moment.
                scheduleRegistration(of: application, after: .seconds(1))
            },
            center.addObserver(of: workspace, for: .didActivateApplication) { [weak self] message in
                // Coming to the front is when an app shows a window it may not have announced, and when an accessory
                // app shows its first.
                guard let self else { return }
                let application = message.application
                if observers[application.processIdentifier] == nil {
                    register(application)
                } else {
                    requestCheckAndFollowUp(of: .apps([application.processIdentifier]), reason: "activated")
                }
            },
            center.addObserver(of: workspace, for: .didUnhideApplication) { [weak self] message in
                // Its windows come back where they were, whatever the panels did meanwhile, and say nothing.
                self?.requestCheckAndFollowUp(of: .apps([message.application.processIdentifier]), reason: "unhidden")
            },
            center.addObserver(of: workspace, for: .didTerminateApplication) { [weak self] message in
                let pid = message.application.processIdentifier
                self?.unregister(pid)
                self?.recheckAttempts[pid] = nil
                self?.placer.forget(pid: pid)
            },
            // Windows on a Space that wasn't shown when they opened, or when the panels changed, couldn't be moved
            // then; nor could any be while the screens slept.
            center.addObserver(of: workspace, for: .activeSpaceDidChange) { [weak self] _ in
                await self?.requestCheck(of: .all, after: Self.spaceChangeSettleDelay, reason: "spaceChanged")
            },
            center.addObserver(of: workspace, for: .screensDidWake) { [weak self] _ in
                await self?.requestCheck(of: .all, after: Self.wakeSettleDelay, reason: "screensWoke")
            },
        ]
    }

    private func registerAllApplications() {
        for application in NSWorkspace.shared.runningApplications where isWatchedEagerly(application) {
            register(application, checking: false)
        }
        Log.avoidance.info("Observing windows of \(self.observers.count) apps")
        // Windows that were already open before we started watching, in one check for every app.
        requestCheckAndFollowUp(of: .all, reason: "registered")
    }

    /// Starts watching `application`'s windows. `checking` checks those it has already, now and once more shortly
    /// after (see ``followUpDelay``).
    private func register(_ application: NSRunningApplication, checking: Bool = true) {
        let pid = application.processIdentifier
        guard mode != .off, isStarted, observers[pid] == nil, isEligible(application), AXIsProcessTrusted()
        else { return }

        let callback: AXObserverCallback = { _, element, notification, context in
            guard let context else { return }
            let avoider = Unmanaged<WindowAvoider>.fromOpaque(context).takeUnretainedValue()
            let notification = notification as String
            MainActor.assumeIsolated {
                avoider.windowDidChange(AccessibilityElement(element: element), notification: notification)
            }
        }
        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else {
            retryRegistration(of: application)
            return
        }

        let applicationElement = AccessibilityElement.application(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [
            kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
            kAXWindowDeminiaturizedNotification,
        ]
        let results = notifications.map {
            AXObserverAddNotification(observer, applicationElement.element, $0 as CFString, context)
        }
        // An app still launching can't answer yet, and one that took some notifications but not others would let
        // windows slip by: either is tried again. A notification an app doesn't send at all has nothing to miss.
        let settled: [AXError] = [.success, .notificationAlreadyRegistered, .notificationUnsupported]
        guard results.contains(.success), results.allSatisfy(settled.contains) else {
            retryRegistration(of: application)
            return
        }

        registrationAttempts[pid] = nil
        // Common modes, so windows still move while Sidelight's own menu or a slider tracks the mouse.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer

        // Windows that were already open before we started watching.
        if checking {
            requestCheckAndFollowUp(of: .apps([pid]), reason: "registered")
        }
    }

    private func retryRegistration(of application: NSRunningApplication) {
        let pid = application.processIdentifier
        let attempts = registrationAttempts[pid, default: 0]
        guard attempts < Self.maximumRegistrationAttempts else {
            Log.avoidance.notice(
                "Not watching \(application.localizedName ?? "?", privacy: .public) until it comes to the front")
            return
        }
        registrationAttempts[pid] = attempts + 1
        let delay = min(Self.registrationRetryDelay * (1 << min(attempts, 8)), Self.maximumRegistrationRetryDelay)
        scheduleRegistration(of: application, after: delay)
    }

    private func scheduleRegistration(of application: NSRunningApplication, after delay: Duration) {
        let pid = application.processIdentifier
        pendingRegistrations[pid]?.cancel()
        pendingRegistrations[pid] = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            pendingRegistrations[pid] = nil
            register(application)
        }
    }

    private func unregister(_ pid: pid_t) {
        registrationAttempts[pid] = nil
        pendingRegistrations.removeValue(forKey: pid)?.cancel()
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    // MARK: Avoidance

    private func windowDidChange(_ window: AccessibilityElement, notification: String) {
        guard mode != .off else { return }
        guard NSEvent.pressedMouseButtons != 0 else {
            avoidOrRecheck(window, eventDate: .now, reason: notification)
            return
        }
        if !windowsAwaitingMouseUp.contains(where: { $0.window.isSameElement(as: window) }) {
            windowsAwaitingMouseUp.append(PendingWindow(window: window, eventDate: .now, reason: notification))
        }
        waitForMouseUp()
    }

    /// Once the mouse button is up: the reservation change that waited for it (unless it's still settling), then the
    /// windows that moved meanwhile, then the checks that came due.
    private func waitForMouseUp() {
        guard mouseUpTask == nil else { return }
        mouseUpTask = Task { [weak self] in
            while NSEvent.pressedMouseButtons != 0 {
                do { try await Task.sleep(for: Self.mouseUpPollInterval) } catch { return }
            }
            guard let self else { return }
            mouseUpTask = nil
            if !settlingTransition.isPending { applyPendingTransition() }
            let pending = windowsAwaitingMouseUp
            windowsAwaitingMouseUp = []
            for item in pending {
                avoidOrRecheck(item.window, eventDate: item.eventDate, reason: item.reason + "+mouseUp")
            }
            runDueChecks()
        }
    }

    /// Moves `window` out from under the panel it overlaps, if any; when it can't be sure yet that it may, checks its
    /// app's windows again shortly.
    private func avoidOrRecheck(_ window: AccessibilityElement, eventDate: Date, reason: String) {
        guard avoid(window, eventDate: eventDate, reason: reason) == .unsure, let pid = window.processIdentifier
        else { return }
        scheduleRecheck(of: pid)
    }

    /// Moves `window` out from under the panel it overlaps, if any, and only when it may move it (see
    /// ``mayMove(_:frame:of:among:onScreen:)``). `windows`, the app's windows, and `onScreen` are what was already read
    /// for this look, if anything.
    @discardableResult
    private func avoid(
        _ window: AccessibilityElement, eventDate: Date, reason: String, among windows: [AccessibilityElement]? = nil,
        onScreen: OnScreenWindows? = nil
    ) -> Outcome {
        let regions = occupiedRegions()
        guard mode != .off,
            !regions.isEmpty,
            let screenHeight = ScreenLayout.primaryScreenHeight,
            let pid = window.processIdentifier,
            pid != ownProcessIdentifier
        else { return .clear }
        // A window just announced, or a busy app's, may not answer yet.
        guard let windowFrame = window.frame else { return .unsure }

        let plans = regions.lazy.compactMap { region in
            let reservation = region.reservation(primaryScreenHeight: screenHeight)
            return AvoidanceGeometry.plan(
                window: windowFrame,
                panel: reservation.frame,
                visibleFrame: AvoidanceGeometry.accessibilityRect(
                    fromCocoa: region.visibleFrame, primaryScreenHeight: screenHeight),
                edge: region.edge,
                mode: self.mode,
                clearance: reservation.clearance
            ).map { (plan: $0, region: region, reservation: reservation) }
        }
        guard let (plan, region, reservation) = plans.first else { return .clear }
        guard !window.isMinimized, !window.isFullScreen else { return .clear }
        // Only now that it would move: whether it's a standard window (one just created may not be yet), and this
        // app's window on the active Space, told apart from its others (one just created may not be shown yet).
        guard window.isStandardWindow,
            let application = NSRunningApplication(processIdentifier: pid),
            mayMove(
                window, frame: windowFrame, of: application,
                among: windows ?? AccessibilityElement.application(pid).readableWindows,
                onScreen: onScreen ?? .current())
        else {
            Log.avoidance.debug("Left a window alone for now, not certainly one to move: \(reason, privacy: .public)")
            return .unsure
        }
        let edge = region.edge
        let managed = ManagedWindow.other(window, pid: pid, launchDate: application.launchDate)
        let display = ScreenLayout.areas(regions: regions).first { $0.id == region.displayID }
        // Read before the placement, which replaces the window's record.
        let previous = display.flatMap { placer.avoidanceBaselines(of: managed, on: $0) }

        let accepted = placer.place(
            managed, at: plan.frame, fallback: plan.shiftFallback.map { (frame: $0, axis: edge) },
            intent: .avoidance(.keepClear), on: display, clearOf: reservation, reason: reason)
        if let accepted {
            remember(
                managed, before: windowFrame, accepted: accepted, role: region.role, previous: previous,
                on: display)
        }

        let delay = Date.now.timeIntervalSince(eventDate) * 1000
        let appName = application.localizedName ?? "?"
        Log.avoidance.debug(
            """
            \(plan.action.rawValue, privacy: .public) app=\(appName, privacy: .public) \
            edge=\(edge.rawValue, privacy: .public) mode=\(self.mode.rawValue, privacy: .public) \
            event=\(reason, privacy: .public) delay=\(delay, format: .fixed(precision: 1))ms \
            from=\(NSStringFromRect(windowFrame), privacy: .public) \
            to=\(NSStringFromRect(accepted ?? .zero), privacy: .public)
            """
        )
        return .moved
    }

    // MARK: Checking what's on screen

    /// Checks the windows of `scope` that are on screen, after `delay`, with every other check due by then. Waits
    /// for the mouse button to come up. `recheck` is the app checked again for a window it couldn't move yet.
    private func requestCheck(
        of scope: CheckScope, after delay: Duration = .zero, reason: String, recheck: pid_t? = nil
    ) {
        guard mode != .off, isStarted else { return }
        pendingChecks.append(PendingCheck(deadline: .now + delay, scope: scope, reason: reason, recheck: recheck))
        scheduleNextCheck()
    }

    /// Checks the windows of `scope` now and once more after ``followUpDelay``.
    private func requestCheckAndFollowUp(of scope: CheckScope, reason: String) {
        requestCheck(of: scope, reason: reason)
        requestCheck(of: scope, after: Self.followUpDelay, reason: reason + "+settled")
    }

    private func scheduleNextCheck() {
        guard let deadline = pendingChecks.map(\.deadline).min() else {
            nextCheck.cancel()
            return
        }
        nextCheck.schedule(after: max(.zero, deadline - .now)) { [weak self] in self?.runDueChecks() }
    }

    /// Runs the checks that are due, as one, unless the mouse button is down: then once it's up.
    private func runDueChecks() {
        guard NSEvent.pressedMouseButtons == 0 else {
            waitForMouseUp()
            return
        }
        let now = ContinuousClock.now
        let due = pendingChecks.filter { $0.deadline <= now }
        pendingChecks.removeAll { $0.deadline <= now }
        if let first = due.first {
            let scope = due.dropFirst().reduce(first.scope) { $0.union($1.scope) }
            let reason = Set(due.map(\.reason)).sorted().joined(separator: "+")
            check(scope, rechecking: Set(due.compactMap(\.recheck)), reason: reason)
        }
        scheduleNextCheck()
    }

    /// Moves the windows of `scope` that overlap a panel on screen now, and checks again later the apps with one it
    /// couldn't be sure of. Only apps the window server shows a window of over a panel are asked anything, so a check
    /// usually costs one call to the window server. Returns how many windows moved.
    ///
    /// - Parameter rechecking: Apps checked again for a window they couldn't move yet. One whose window still isn't
    ///   shown over a panel is checked again later, as it may only be about to be.
    @discardableResult
    private func check(_ scope: CheckScope, rechecking: Set<pid_t> = [], reason: String) -> Int {
        let regions = occupiedRegions()
        guard mode != .off, isStarted, permission.isTrusted, !regions.isEmpty,
            let screenHeight = ScreenLayout.primaryScreenHeight
        else {
            return 0
        }
        let panels = regions.map { $0.reservation(primaryScreenHeight: screenHeight).frame }
        let onScreen = OnScreenWindows.current()
        let candidates = onScreen.processes(overlapping: panels).filter(scope.contains)

        var moved = 0
        var unsure: Set<pid_t> = []
        for pid in candidates {
            guard let application = NSRunningApplication(processIdentifier: pid), isEligible(application) else {
                continue
            }
            // The window server shows one over a panel, but the app can't list its windows right now (it's busy).
            guard let windows = AccessibilityElement.application(pid).readableWindows else {
                unsure.insert(pid)
                continue
            }
            for window in windows {
                switch avoid(window, eventDate: .now, reason: reason, among: windows, onScreen: onScreen) {
                case .moved: moved += 1
                case .unsure: unsure.insert(pid)
                case .clear: break
                }
            }
        }
        // Apps it looked at and is sure about now start over; the others are checked again, later and later, a few
        // times: those it's unsure of, and those checked again whose window isn't shown over a panel yet.
        for pid in candidates where !unsure.contains(pid) { recheckAttempts[pid] = nil }
        for pid in unsure.union(rechecking.subtracting(candidates)) { scheduleRecheck(of: pid) }
        return moved
    }

    /// Checks `pid`'s windows again after the next of ``recheckDelays``; after the last, leaves them to its next event.
    private func scheduleRecheck(of pid: pid_t) {
        let attempt = recheckAttempts[pid, default: 0]
        guard attempt < Self.recheckDelays.count else {
            recheckAttempts[pid] = nil
            Log.avoidance.debug("Left a window over the panel alone: it never became one to move")
            return
        }
        recheckAttempts[pid] = attempt + 1
        requestCheck(of: .apps([pid]), after: Self.recheckDelays[attempt], reason: "recheck", recheck: pid)
    }

    private func cancelChecks() {
        pendingChecks = []
        nextCheck.cancel()
        recheckAttempts = [:]
    }
}

extension WindowAvoider {
    /// Whether Sidelight may move `window`, now at `frame`: a window of an app it may move, on the active Space as the
    /// window server shows it in `onScreen`, and told apart from every other window of the app by its frame.
    /// Accessibility can't say which Space a window is on without private API, so anything short of complete evidence
    /// counts as no: the app's window list unreadable (`nil`) or missing `window`, or any other window's frame
    /// unreadable, since that window could be its twin on the active Space. Every move goes through this.
    fileprivate func mayMove(
        _ window: AccessibilityElement, frame: CGRect, of application: NSRunningApplication,
        among windows: [AccessibilityElement]?, onScreen: OnScreenWindows
    ) -> Bool {
        guard isEligible(application), let windows, windows.contains(where: { $0.isSameElement(as: window) }) else {
            return false
        }
        var siblings: [CGRect] = []
        for sibling in windows where !sibling.isSameElement(as: window) {
            guard let siblingFrame = sibling.frame else { return false }
            siblings.append(siblingFrame)
        }
        return onScreen.contains(frame, of: application.processIdentifier, siblings: siblings)
    }
}

/// How much of `rect` lies inside `other`.
private func area(_ rect: CGRect, _ other: CGRect) -> CGFloat {
    let overlap = rect.intersection(other)
    return overlap.isNull ? 0 : overlap.width * overlap.height
}
