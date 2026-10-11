import AppKit
import SidelightCore

/// Brings a Codex session to the front, wherever it runs:
///
/// - Sessions open in a terminal, an editor or another app are brought forward there, at the session where
///   ``SessionHost`` can.
/// - Everything else opens in the Codex desktop app through its `codex://threads/<id>` link: the app's own
///   sessions, and closed ones from any client, since the app lists them all.
enum CodexSessionOpener {
    static let appBundleID = "com.openai.codex"

    static var isAppInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID) != nil
    }

    /// Whether there's anything to bring forward: a process still running, or the desktop app to open it in.
    static func canOpen(_ session: CodexSession) -> Bool {
        session.pid != nil || isAppInstalled
    }

    /// Beeps when nothing could be brought forward, such as a session running in tmux without the desktop app.
    static func open(_ session: CodexSession) {
        Task {
            if await !bringForward(session) { NSSound.beep() }
        }
    }

    static func openInApp(_ session: CodexSession) {
        if let url = CodexSessionLinks.appURL(threadID: session.id) { NSWorkspace.shared.open(url) }
    }

    static func copyResumeCommand(of session: CodexSession) {
        SessionHost.copy(CodexSessionLinks.resumeCommand(threadID: session.id, cwd: session.cwd))
    }

    private static func bringForward(_ session: CodexSession) async -> Bool {
        if let pid = session.pid, let app = SessionHost.app(of: pid), app.bundleIdentifier != appBundleID {
            return await SessionHost.bringForward(
                app, pid: pid, cwd: session.cwd, title: session.title, opensFolder: session.surface == .ide,
                log: Log.codexSessions)
        }
        guard isAppInstalled, let url = CodexSessionLinks.appURL(threadID: session.id) else { return false }
        return NSWorkspace.shared.open(url)
    }
}
