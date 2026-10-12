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

    /// Where a click takes a session, decided in one place so that what a row says is what it does.
    enum Destination {
        /// The app the session's process runs in, when that isn't the Codex app.
        case host(NSRunningApplication, pid: Int32)
        /// The Codex app, through the session's link.
        case app(URL)
    }

    /// `nil` when there's nowhere to go: no app runs the process, and the desktop app isn't installed.
    static func destination(of session: CodexSession) -> Destination? {
        if let pid = session.pid, let app = SessionHost.app(of: pid), app.bundleIdentifier != appBundleID {
            return .host(app, pid: pid)
        }
        guard isAppInstalled, let url = CodexSessionLinks.appURL(threadID: session.id) else { return nil }
        return .app(url)
    }

    /// Whether a click brings anything forward, so a row never offers what it can't do.
    static func canOpen(_ session: CodexSession) -> Bool {
        destination(of: session) != nil
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
        switch destination(of: session) {
        case .host(let app, let pid):
            await SessionHost.bringForward(
                app, pid: pid, cwd: session.cwd, title: session.title, opensFolder: session.surface == .ide,
                log: Log.codexSessions)
        case .app(let url): NSWorkspace.shared.open(url)
        case nil: false
        }
    }
}
