import AppKit
import SidelightCore

/// Brings a Claude Code session to the front, wherever it runs:
///
/// - Desktop app sessions open through its `claude://` link, even after their process has exited.
/// - Terminals, VS Code and other apps are brought forward at the session, as ``SessionHost`` can.
enum ClaudeSessionOpener {
    /// Where a click takes a session, decided in one place so that what a row says is what it does.
    enum Destination {
        /// The desktop app, through the session's link.
        case app(URL)
        /// The app the session's process runs in.
        case host(NSRunningApplication, pid: Int32)
    }

    /// `nil` when there's nowhere to go, such as a session in tmux or a closed one from a terminal.
    static func destination(of session: ClaudeSession) -> Destination? {
        if let url = desktopURL(of: session) { return .app(url) }
        guard let pid = session.pid, let app = SessionHost.app(of: pid) else { return nil }
        return .host(app, pid: pid)
    }

    /// Whether a click brings anything forward, so a row never offers what it can't do.
    static func canOpen(_ session: ClaudeSession) -> Bool {
        destination(of: session) != nil
    }

    /// Beeps when nothing could be brought forward, such as a session running in tmux.
    static func open(_ session: ClaudeSession) {
        Task {
            if await !bringForward(session) { NSSound.beep() }
        }
    }

    static func copyResumeCommand(of session: ClaudeSession) {
        SessionHost.copy(ClaudeSessionLinks.resumeCommand(sessionID: session.id, cwd: session.cwd))
    }

    private static func desktopURL(of session: ClaudeSession) -> URL? {
        session.desktopSessionID.flatMap(ClaudeSessionLinks.desktopURL(sessionID:))
    }

    private static func bringForward(_ session: ClaudeSession) async -> Bool {
        switch destination(of: session) {
        case .app(let url): NSWorkspace.shared.open(url)
        case .host(let app, let pid):
            await SessionHost.bringForward(
                app, pid: pid, cwd: session.cwd, title: session.title, opensFolder: session.surface == .vscode,
                log: Log.claudeSessions)
        case nil: false
        }
    }
}
