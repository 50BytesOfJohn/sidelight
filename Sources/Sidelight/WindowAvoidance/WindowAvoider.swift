import AppKit
import ApplicationServices
import Observation
import SidelightCore
import os

/// A panel's frame and the visible frame of its screen, both in Cocoa coordinates, and the edge it sits on.
struct PanelRegion {
    var frame: CGRect
    var visibleFrame: CGRect
    var edge: PanelPosition
}

/// Keeps other apps' windows out from under the panels, using the Accessibility API.
///
/// Watches every regular app for window creation, moves and resizes, and moves or shrinks any standard window
/// that ends up overlapping the panel (see ``AvoidanceGeometry``). While the user is dragging, it waits for
/// mouse-up instead of fighting the drag.
@Observable
final class WindowAvoider {
    static let trustPollInterval: Duration = .seconds(3)
    static let mouseUpPollInterval: Duration = .milliseconds(50)
    static let registrationRetryDelay: Duration = .milliseconds(500)
    static let maximumRegistrationAttempts = 10

    /// Whether the user granted Accessibility access.
    private(set) var isTrusted = AXIsProcessTrusted()

    @ObservationIgnored var mode: WindowAvoidanceMode = .smart
    /// The panels to keep clear; empty while they're hidden.
    @ObservationIgnored var occupiedRegions: () -> [PanelRegion] = { [] }

    private struct PendingWindow {
        let window: AccessibilityElement
        let eventDate: Date
        let reason: String
    }

    @ObservationIgnored private var observers: [pid_t: AXObserver] = [:]
    @ObservationIgnored private var registrationAttempts: [pid_t: Int] = [:]
    @ObservationIgnored private var windowsAwaitingMouseUp: [PendingWindow] = []
    @ObservationIgnored private var mouseUpTask: Task<Void, Never>?
    @ObservationIgnored private var trustPollTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceObservations: [NotificationCenter.ObservationToken] = []

    private let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier

    /// Starts observing apps. Without Accessibility access yet, polls until it's granted.
    func start(promptingForAccess: Bool) {
        if Self.checkTrust(prompting: promptingForAccess) {
            isTrusted = true
            registerAllApplications()
        } else {
            Log.avoidance.info("Accessibility access not granted yet; waiting for it")
            pollForTrust()
        }
        observeWorkspace()
    }

    /// Shows the system prompt and opens the Accessibility pane in System Settings.
    func requestAccess() {
        _ = Self.checkTrust(prompting: true)
        SystemSettingsPane.accessibilityPrivacy.open()
    }

    /// Moves every overlapping window right now. Returns how many were moved.
    @discardableResult
    func avoidAllWindows() -> Int {
        let moved = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownProcessIdentifier }
            .flatMap { AccessibilityElement.application($0.processIdentifier).windows }
            .filter { avoid($0, eventDate: .now, reason: "avoidAll") }
            .count
        Log.avoidance.info("Moved \(moved) windows")
        return moved
    }

    // MARK: Observation

    private static func checkTrust(prompting: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompting] as CFDictionary)
    }

    private func pollForTrust() {
        trustPollTask = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: Self.trustPollInterval) } catch { return }
                guard AXIsProcessTrusted() else { continue }
                self?.isTrusted = true
                self?.registerAllApplications()
                return
            }
        }
    }

    private func observeWorkspace() {
        let workspace = NSWorkspace.shared
        let center = workspace.notificationCenter
        workspaceObservations = [
            center.addObserver(of: workspace, for: .didLaunchApplication) { [weak self] message in
                let application = message.application
                // Freshly launched apps usually aren't Accessibility-ready for a moment.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    self?.register(application)
                }
            },
            center.addObserver(of: workspace, for: .didActivateApplication) { [weak self] message in
                self?.register(message.application)
            },
            center.addObserver(of: workspace, for: .didTerminateApplication) { [weak self] message in
                self?.unregister(message.application.processIdentifier)
            },
        ]
    }

    private func registerAllApplications() {
        for application in NSWorkspace.shared.runningApplications where application.activationPolicy == .regular {
            register(application)
        }
        Log.avoidance.info("Observing windows of \(self.observers.count) apps")
    }

    private func register(_ application: NSRunningApplication) {
        let pid = application.processIdentifier
        guard pid != ownProcessIdentifier, observers[pid] == nil, application.activationPolicy == .regular,
            AXIsProcessTrusted()
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
        Task { [weak self] in
            try? await Task.sleep(for: Self.registrationRetryDelay)
            self?.register(application)
        }
    }

    private func unregister(_ pid: pid_t) {
        registrationAttempts[pid] = nil
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

    private func waitForMouseUp() {
        guard mouseUpTask == nil else { return }
        mouseUpTask = Task { [weak self] in
            while NSEvent.pressedMouseButtons != 0 {
                do { try await Task.sleep(for: Self.mouseUpPollInterval) } catch { return }
            }
            guard let self else { return }
            mouseUpTask = nil
            let pending = windowsAwaitingMouseUp
            windowsAwaitingMouseUp = []
            for item in pending { avoid(item.window, eventDate: item.eventDate, reason: item.reason + "+mouseUp") }
        }
    }

    /// Moves `window` out from under the panel it overlaps, if any. Returns whether it was moved.
    @discardableResult
    private func avoid(_ window: AccessibilityElement, eventDate: Date, reason: String) -> Bool {
        let regions = occupiedRegions()
        guard mode != .off,
            !regions.isEmpty,
            let primaryScreen = NSScreen.primary,
            window.processIdentifier != ownProcessIdentifier,
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
            ).map { (plan: $0, edge: region.edge) }
        }
        guard let (plan, edge) = plans.first else { return false }

        var action = plan.action.rawValue
        window.setFrame(plan.frame)
        if let fallback = plan.shiftFallback, let actual = window.frame,
            AvoidanceGeometry.clipWasRefused(requested: plan.frame, actual: actual, edge: edge)
        {
            action = "shift(minimumSize)"
            window.setFrame(fallback)
        }

        let delay = Date.now.timeIntervalSince(eventDate) * 1000
        let appName =
            window.processIdentifier.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "?"
        Log.avoidance.debug(
            """
            \(action, privacy: .public) app=\(appName, privacy: .public) edge=\(edge.rawValue, privacy: .public) \
            mode=\(self.mode.rawValue, privacy: .public) event=\(reason, privacy: .public) \
            delay=\(delay, format: .fixed(precision: 1))ms from=\(NSStringFromRect(windowFrame), privacy: .public) \
            to=\(NSStringFromRect(window.frame ?? .zero), privacy: .public)
            """
        )
        return true
    }
}
