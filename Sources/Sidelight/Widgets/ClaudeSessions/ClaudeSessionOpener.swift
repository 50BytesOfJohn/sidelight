import AppKit
import SidelightCore

/// Brings a Claude Code session to the front, wherever it runs:
///
/// - Desktop app sessions open through its `claude://` link, even after their process has exited.
/// - Terminals, VS Code and other apps are brought forward at the session, as ``SessionHost`` can.
enum ClaudeSessionOpener {
    /// Whether there's anything to bring forward: a desktop session, or a process still running.
    static func canOpen(_ session: ClaudeSession) -> Bool {
        desktopURL(of: session) != nil || session.pid != nil
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
        if let url = desktopURL(of: session) { return NSWorkspace.shared.open(url) }
        guard let pid = session.pid, let app = SessionHost.app(of: pid) else { return false }
        return await SessionHost.bringForward(
            app, pid: pid, cwd: session.cwd, title: session.title, opensFolder: session.surface == .vscode,
            log: Log.claudeSessions)
    }
}
