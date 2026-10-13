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
/// Watches every regular app for window creation, moves and resizes, and moves or shrinks any standard window
/// that ends up overlapping the panel (see ``AvoidanceGeometry``). While the user is dragging, it waits for
/// mouse-up instead of fighting the drag.
///
/// It remembers where each window was before it moved it, so when a strip is released (the panels hide, or the
/// details panel gives way to the side panel again) windows nobody touched since go back. See
/// ``ReservationTransition`` for exactly what moves.
///
/// It only ever moves a window it can be sure of: a standard window of an eligible app, on the active Space as the
/// window server lists it, and told apart from that app's other windows (see ``OnScreenWindows``). Anything less
/// certain is left alone. Every move, whether avoidance, putting back or following an edge, goes through that check.
///
/// With avoidance off it watches nothing, asks for nothing and remembers nothing, so it costs nothing.
@Observable
final class WindowAvoider {
    /// While Accessibility access isn't granted, it's checked this often at first, then less and less often.
    static let trustPollInterval: Duration = .seconds(3)
    static let maximumTrustPollInterval: Duration = .seconds(60)
    static let mouseUpPollInterval: Duration = .milliseconds(50)
    static let registrationRetryDelay: Duration = .milliseconds(500)
    static let maximumRegistrationAttempts = 10

    /// Whether the user granted Accessibility access.
    private(set) var isTrusted = AXIsProcessTrusted()

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

    /// A window Sidelight moved, and where to put it back.
    private struct MovedWindow {
        let window: AccessibilityElement
        let processIdentifier: pid_t
        /// Process identifiers are reused: a window of a later process with the same one isn't this window.
        let launchDate: Date?
        let displayID: Display.ID
        /// The display's frame when the window was moved. Once it changes, the frames below mean nothing.
        let displayFrame: CGRect
        var baselines: WindowBaselines

        func isWindow(_ other: AccessibilityElement, of pid: pid_t) -> Bool {
            processIdentifier == pid && window.isSameElement(as: other)
        }
    }

    @ObservationIgnored private var observers: [pid_t: AXObserver] = [:]
    @ObservationIgnored private var registrationAttempts: [pid_t: Int] = [:]
    /// Delayed registrations (fresh launches and retries), cancelled when avoidance turns off or the app quits.
    @ObservationIgnored private var pendingRegistrations: [pid_t: Task<Void, Never>] = [:]
    @ObservationIgnored private var windowsAwaitingMouseUp: [PendingWindow] = []
    @ObservationIgnored private var mouseUpTask: Task<Void, Never>?
    @ObservationIgnored private let trustPoll = PacedTask()
    @ObservationIgnored private var workspaceObservations: [NotificationCenter.ObservationToken] = []
    @ObservationIgnored private var isStarted = false
    /// Windows Sidelight moved and may put back. Only ever in memory, and only for this run.
    @ObservationIgnored private var movedWindows: [MovedWindow] = []
    /// The strips before a change that's waiting: for a panel to settle, or the mouse button to come up. Later
    /// changes keep this start and go to wherever things are by then, so a change undone meanwhile moves nothing,
    /// and a change replaced by another moves windows once.
    @ObservationIgnored private var pendingTransitionStart: [PanelRegion]?
    @ObservationIgnored private let settlingTransition = DelayedTask()

    private let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    /// Which apps' windows it may move, besides being regular apps other than Sidelight.
    @ObservationIgnored private let includes: (NSRunningApplication) -> Bool

    /// - Parameter includes: Which apps' windows it may move: every regular app, unless the app's composition
    ///   narrows it (to one disposable app, say, when trying window movement out).
    init(includes: @escaping (NSRunningApplication) -> Bool = { _ in true }) {
        self.includes = includes
    }

    /// Whether `application`'s windows may be moved.
    private func isEligible(_ application: NSRunningApplication) -> Bool {
        application.activationPolicy == .regular && application.processIdentifier != ownProcessIdentifier
            && includes(application)
    }

    /// Starts observing apps while ``mode`` isn't off. Without Accessibility access yet, polls until it's granted.
    func start(promptingForAccess: Bool) {
        guard !isStarted else { return }
        isStarted = true
        if mode != .off { activate(promptingForAccess: promptingForAccess) }
    }

    /// Shows the system prompt and opens the Accessibility pane in System Settings.
    func requestAccess() {
        _ = Self.checkTrust(prompting: true)
        SystemSettingsPane.accessibilityPrivacy.open()
        // The person is about to grant it: notice that soon.
        if trustPoll.isRunning { pollForTrust() }
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
        let moved = NSWorkspace.shared.runningApplications
            .filter(isEligible)
            .flatMap { AccessibilityElement.application($0.processIdentifier).windows }
            .filter { avoid($0, eventDate: .now, reason: "avoidAll") }
            .count
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
        movedWindows = []
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
            accessWasRevoked()
            return
        }
        guard let primaryScreen = NSScreen.primary else { return }
        let screenHeight = primaryScreen.frame.height
        func accessibility(_ rect: CGRect) -> CGRect {
            AvoidanceGeometry.accessibilityRect(fromCocoa: rect, primaryScreenHeight: screenHeight)
        }

        // Frames on a display that's gone or changed shape since can't be put back anywhere meaningful.
        let displays = Display.connected()
        movedWindows.removeAll { entry in
            !displays.contains { $0.id == entry.displayID && $0.frame == entry.displayFrame }
        }
        guard displays.contains(where: { changed.contains($0.id) }) else { return }
        let displayFrames = displays.map { (display: $0, frame: accessibility($0.frame)) }
        let onScreen = OnScreenWindows.current()

        var remaining = movedWindows
        var updated: [MovedWindow] = []
        var counts: [ReservationTransition.Move.Reason: Int] = [:]
        for application in NSWorkspace.shared.runningApplications where isEligible(application) {
            let pid = application.processIdentifier
            // An app whose windows can't all be listed can't have one told apart from the others: none moves, and
            // what was remembered of them is forgotten.
            guard let allWindows = AccessibilityElement.application(pid).readableWindows else { continue }
            let windows: [(window: AccessibilityElement, frame: CGRect)] = allWindows.compactMap { window in
                guard window.isStandardWindow, !window.isFullScreen, !window.isMinimized, let frame = window.frame
                else { return nil }
                return (window, frame)
            }
            for (window, frame) in windows {
                // The display holding most of it, if its strip changed.
                guard
                    let display = displayFrames.max(by: { area(frame, $0.frame) < area(frame, $1.frame) }),
                    area(frame, display.frame) > 0, changed.contains(display.display.id)
                else { continue }
                let entry = remaining.firstIndex { $0.isWindow(window, of: pid) }.map { remaining.remove(at: $0) }
                // Another Space, or not told apart from another window: never moved, and no longer put back.
                guard mayMove(window, frame: frame, of: application, among: allWindows, onScreen: onScreen) else {
                    continue
                }

                let id = display.display.id
                // An app that quit, and another that got its process identifier since: not the window remembered.
                let launchDate = application.launchDate
                let baselines = entry.flatMap { $0.displayID == id && $0.launchDate == launchDate ? $0.baselines : nil }
                let decision = ReservationTransition.decide(
                    window: frame, baselines: baselines,
                    from: before[id].map { Reservation(frame: accessibility($0.frame), edge: $0.edge, role: $0.role) },
                    to: after[id].map { Reservation(frame: accessibility($0.frame), edge: $0.edge, role: $0.role) },
                    visibleFrame: accessibility(display.display.visibleFrame), displayFrame: display.frame, mode: mode)

                let kept: WindowBaselines?
                switch decision {
                case .leave(let baselines):
                    kept = baselines
                case .move(let move):
                    let axis = move.reason == .follow ? before[id]?.edge : after[id]?.edge
                    kept = perform(move, on: window, from: frame, axis: axis ?? .left, previous: baselines)
                    counts[move.reason, default: 0] += 1
                }
                if let kept {
                    updated.append(
                        MovedWindow(
                            window: window, processIdentifier: pid, launchDate: launchDate, displayID: id,
                            displayFrame: display.display.frame, baselines: kept))
                }
            }
        }
        // Windows remembered on these displays and not found (closed, minimized, full screen, their app quit) are
        // forgotten; those on other displays stay as they were.
        movedWindows = remaining.filter { !changed.contains($0.displayID) } + updated
        let summary = counts.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " ")
        Log.avoidance.info("Reservations changed on \(changed.count) displays: \(summary, privacy: .public)")
    }

    /// Moves `window` as `move` says, falling back to keeping its size if the app refuses to resize it, and returns
    /// what to remember: where the app actually put it, never where it was asked to go.
    private func perform(
        _ move: ReservationTransition.Move, on window: AccessibilityElement, from frame: CGRect, axis: PanelPosition,
        previous: WindowBaselines?
    ) -> WindowBaselines? {
        window.setFrame(move.frame)
        var accepted = window.frame
        if let fallback = move.fallback, let actual = accepted,
            AvoidanceGeometry.clipWasRefused(requested: move.frame, actual: actual, edge: axis)
        {
            window.setFrame(fallback)
            accepted = window.frame
        }
        // Gone meanwhile.
        guard let accepted else { return nil }
        // Refused outright: nothing moved, so there's nothing new to put back.
        guard !ReservationTransition.isUnchanged(accepted, since: frame) else {
            return previous.flatMap { ReservationTransition.isUnchanged(frame, since: $0.accepted) ? $0 : nil }
        }
        Log.avoidance.debug(
            """
            \(move.reason.rawValue, privacy: .public) from=\(NSStringFromRect(frame), privacy: .public) \
            to=\(NSStringFromRect(accepted), privacy: .public)
            """
        )
        return move.baselines(accepted: accepted)
    }

    /// Notes that everyday avoidance moved `window` from `before` to `accepted` to keep `region` clear.
    ///
    /// A window still where Sidelight last left it keeps the baselines it had, with the new accepted frame. Otherwise
    /// it starts over, and only the side panel or bar gives it a way back: hiding the panels puts back what they
    /// pushed. The details panel's way back belongs to the windows it took the space from when it opened (see
    /// ``ReservationTransition``). A window it pushes later, opened or moved since, has no frame from before the
    /// session to return to; it can still follow the edge it's left touching when the details panel closes.
    private func remember(
        _ window: AccessibilityElement, pid: pid_t, launchDate: Date?, before: CGRect, accepted: CGRect,
        region: PanelRegion
    ) {
        guard !ReservationTransition.isUnchanged(accepted, since: before) else { return }
        let previous = movedWindows.firstIndex { $0.isWindow(window, of: pid) }.map { movedWindows.remove(at: $0) }
        var baselines =
            previous.flatMap { entry in
                entry.displayID == region.displayID && entry.launchDate == launchDate
                    && ReservationTransition.isUnchanged(before, since: entry.baselines.accepted)
                    ? entry.baselines : nil
            } ?? WindowBaselines(accepted: accepted)
        if region.role == .main { baselines.main = baselines.main ?? before }
        baselines.accepted = accepted
        // Nothing to put back: nothing to remember.
        guard baselines.main != nil || baselines.details != nil else { return }
        movedWindows.append(
            MovedWindow(
                window: window, processIdentifier: pid, launchDate: launchDate, displayID: region.displayID,
                displayFrame: region.displayFrame, baselines: baselines))
    }

    /// Without access, nothing can move: forget what was moved, and stop watching until access comes back. Then
    /// windows are kept clear afresh.
    private func accessWasRevoked() {
        guard isTrusted else { return }
        Log.avoidance.notice("Accessibility access was revoked; forgetting moved windows")
        isTrusted = false
        movedWindows = []
        pendingTransitionStart = nil
        settlingTransition.cancel()
        windowsAwaitingMouseUp = []
        for pid in Array(observers.keys) { unregister(pid) }
        pollForTrust()
    }

    // MARK: Observation

    private static func checkTrust(prompting: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompting] as CFDictionary)
    }

    private func activate(promptingForAccess: Bool) {
        if Self.checkTrust(prompting: promptingForAccess) {
            isTrusted = true
            registerAllApplications()
        } else {
            Log.avoidance.info("Accessibility access not granted yet; waiting for it")
            pollForTrust()
        }
        observeWorkspace()
    }

    private func deactivate() {
        trustPoll.stop()
        mouseUpTask?.cancel()
        mouseUpTask = nil
        windowsAwaitingMouseUp = []
        pendingTransitionStart = nil
        settlingTransition.cancel()
        movedWindows = []
        for task in pendingRegistrations.values { task.cancel() }
        pendingRegistrations = [:]
        for token in workspaceObservations { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceObservations = []
        for pid in Array(observers.keys) { unregister(pid) }
        Log.avoidance.info("Stopped observing windows")
    }

    private func pollForTrust() {
        var interval = Self.trustPollInterval
        trustPoll.start(after: interval) { [weak self] in
            guard AXIsProcessTrusted() else {
                interval = min(interval * 2, Self.maximumTrustPollInterval)
                return interval
            }
            self?.isTrusted = true
            self?.registerAllApplications()
            return nil
        }
    }

    private func observeWorkspace() {
        guard workspaceObservations.isEmpty else { return }
        let workspace = NSWorkspace.shared
        let center = workspace.notificationCenter
        workspaceObservations = [
            center.addObserver(of: workspace, for: .didLaunchApplication) { [weak self] message in
                let application = message.application
                // Freshly launched apps usually aren't Accessibility-ready for a moment.
                self?.scheduleRegistration(of: application, after: .seconds(1))
            },
            center.addObserver(of: workspace, for: .didActivateApplication) { [weak self] message in
                self?.register(message.application)
            },
            center.addObserver(of: workspace, for: .didTerminateApplication) { [weak self] message in
                let pid = message.application.processIdentifier
                self?.unregister(pid)
                self?.movedWindows.removeAll { $0.processIdentifier == pid }
            },
        ]
    }

    private func registerAllApplications() {
        for application in NSWorkspace.shared.runningApplications where isEligible(application) {
            register(application)
        }
        Log.avoidance.info("Observing windows of \(self.observers.count) apps")
    }

    private func register(_ application: NSRunningApplication) {
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
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let applicationElement = AccessibilityElement.application(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification]
        let added = notifications.count {
            AXObserverAddNotification(observer, applicationElement.element, $0 as CFString, context) == .success
        }
        guard added > 0 else {
            retryRegistration(of: application)
            return
        }

        registrationAttempts[pid] = nil
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer

        // Windows that were already open before we started watching.
        if mode != .off {
            for window in applicationElement.windows { avoid(window, eventDate: .now, reason: "registered") }
        }
    }

    private func retryRegistration(of application: NSRunningApplication) {
        let pid = application.processIdentifier
        let attempts = registrationAttempts[pid, default: 0]
        guard attempts < Self.maximumRegistrationAttempts else { return }
        registrationAttempts[pid] = attempts + 1
        scheduleRegistration(of: application, after: Self.registrationRetryDelay)
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
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    // MARK: Avoidance

    private func windowDidChange(_ window: AccessibilityElement, notification: String) {
        guard mode != .off else { return }
        guard NSEvent.pressedMouseButtons != 0 else {
            avoid(window, eventDate: .now, reason: notification)
            return
        }
        if !windowsAwaitingMouseUp.contains(where: { $0.window.isSameElement(as: window) }) {
            windowsAwaitingMouseUp.append(PendingWindow(window: window, eventDate: .now, reason: notification))
        }
        waitForMouseUp()
    }

    /// Once the mouse button is up: the reservation change that waited for it (unless it's still settling), then the
    /// windows that moved meanwhile.
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
            for item in pending { avoid(item.window, eventDate: item.eventDate, reason: item.reason + "+mouseUp") }
        }
    }

    /// Moves `window` out from under the panel it overlaps, if any, and only when it may move it (see
    /// ``mayMove(_:frame:of:)``). Returns whether it was moved.
    @discardableResult
    private func avoid(_ window: AccessibilityElement, eventDate: Date, reason: String) -> Bool {
        let regions = occupiedRegions()
        guard mode != .off,
            !regions.isEmpty,
            let primaryScreen = NSScreen.primary,
            let pid = window.processIdentifier,
            pid != ownProcessIdentifier,
            window.isStandardWindow,
            !window.isFullScreen,
            !window.isMinimized,
            let windowFrame = window.frame
        else { return false }

        let screenHeight = primaryScreen.frame.height
        let plans = regions.lazy.compactMap { region in
            AvoidanceGeometry.plan(
                window: windowFrame,
                panel: AvoidanceGeometry.accessibilityRect(fromCocoa: region.frame, primaryScreenHeight: screenHeight),
                visibleFrame: AvoidanceGeometry.accessibilityRect(
                    fromCocoa: region.visibleFrame, primaryScreenHeight: screenHeight),
                edge: region.edge,
                mode: self.mode
            ).map { (plan: $0, region: region) }
        }
        guard let (plan, region) = plans.first else { return false }
        // Only now that it would move: whether it's this app's window on the active Space, told apart from its others.
        guard let application = NSRunningApplication(processIdentifier: pid),
            mayMove(
                window, frame: windowFrame, of: application,
                among: AccessibilityElement.application(pid).readableWindows, onScreen: .current())
        else {
            Log.avoidance.debug("Left a window alone, not certainly on the active Space: \(reason, privacy: .public)")
            return false
        }
        let edge = region.edge

        var action = plan.action.rawValue
        window.setFrame(plan.frame)
        if let fallback = plan.shiftFallback, let actual = window.frame,
            AvoidanceGeometry.clipWasRefused(requested: plan.frame, actual: actual, edge: edge)
        {
            action = "shift(minimumSize)"
            window.setFrame(fallback)
        }
        let accepted = window.frame
        if let accepted {
            remember(
                window, pid: pid, launchDate: application.launchDate, before: windowFrame, accepted: accepted,
                region: region)
        }

        let delay = Date.now.timeIntervalSince(eventDate) * 1000
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        Log.avoidance.debug(
            """
            \(action, privacy: .public) app=\(appName, privacy: .public) edge=\(edge.rawValue, privacy: .public) \
            mode=\(self.mode.rawValue, privacy: .public) event=\(reason, privacy: .public) \
            delay=\(delay, format: .fixed(precision: 1))ms from=\(NSStringFromRect(windowFrame), privacy: .public) \
            to=\(NSStringFromRect(accepted ?? .zero), privacy: .public)
            """
        )
        return true
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
