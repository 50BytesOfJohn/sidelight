import ApplicationServices
import Observation
import SidelightCore
import os

/// Whether Sidelight has Accessibility access, which moving other apps' windows and reading their selection need.
///
/// macOS sends nothing when access is granted, so while it isn't and a feature that needs it is on (window avoidance,
/// the window manager), it's checked every few seconds at first, then less and less often. Otherwise nothing runs.
@Observable
final class AccessibilityPermission {
    /// While access isn't granted, it's checked this often at first, then less and less often.
    static let pollInterval: Duration = .seconds(3)
    static let maximumPollInterval: Duration = .seconds(60)

    /// What needs access, and so a poll for it.
    enum Need: Hashable {
        case avoidance, windowManager
    }

    /// Whether the user granted Accessibility access, as last checked.
    private(set) var isTrusted = AXIsProcessTrusted()

    @ObservationIgnored private var needs: Set<Need> = []
    @ObservationIgnored private var listeners: [(Bool) -> Void] = []
    @ObservationIgnored private let poll = PacedTask()

    /// Calls `listener` on the main actor whenever access is granted or revoked.
    func onChange(_ listener: @escaping (_ isTrusted: Bool) -> Void) {
        listeners.append(listener)
    }

    /// Says whether `need` wants access, so it's watched for while missing.
    func setNeeded(_ isNeeded: Bool, by need: Need) {
        if isNeeded { needs.insert(need) } else { needs.remove(need) }
        updatePoll()
    }

    /// Checks access now, showing the system prompt if `prompting` and it's missing. Returns whether it's granted.
    @discardableResult
    func check(prompting: Bool) -> Bool {
        update(AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompting] as CFDictionary))
        return isTrusted
    }

    /// Checks access now, without asking. Returns whether it's granted.
    @discardableResult
    func refresh() -> Bool {
        check(prompting: false)
    }

    /// Shows the system prompt and opens the Accessibility pane in System Settings.
    func request() {
        check(prompting: true)
        SystemSettingsPane.accessibilityPrivacy.open()
        // The person is about to grant it: notice that soon.
        if poll.isRunning { startPoll() }
    }

    private func update(_ trusted: Bool) {
        guard trusted != isTrusted else { return updatePoll() }
        isTrusted = trusted
        Log.app.notice("Accessibility access \(trusted ? "granted" : "revoked", privacy: .public)")
        updatePoll()
        for listener in listeners { listener(trusted) }
    }

    private func updatePoll() {
        if isTrusted || needs.isEmpty {
            poll.stop()
        } else if !poll.isRunning {
            startPoll()
        }
    }

    private func startPoll() {
        var interval = Self.pollInterval
        poll.start(after: interval) { [weak self] in
            guard AXIsProcessTrusted() else {
                interval = min(interval * 2, Self.maximumPollInterval)
                return interval
            }
            self?.update(true)
            return nil
        }
    }
}
