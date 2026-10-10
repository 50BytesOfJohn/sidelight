import AppKit
import SidelightCore
import os

/// Brings a Claude Code session to the front, wherever it runs:
///
/// - Desktop app sessions open through its `claude://` link, even after their process has exited.
/// - Terminal, iTerm2 and Ghostty are asked (AppleScript) for the exact tab, by its tty or its folder and title.
///   macOS asks once per app whether Sidelight may do this; without it, the app just comes forward.
/// - VS Code and its forks reopen the session's folder, which focuses the window that has it.
/// - Any other app the session runs in (another terminal, an app driving the Agent SDK) comes forward.
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            ClaudeSessionLinks.resumeCommand(sessionID: session.id, cwd: session.cwd), forType: .string)
    }

    private static func desktopURL(of session: ClaudeSession) -> URL? {
        session.desktopSessionID.flatMap(ClaudeSessionLinks.desktopURL(sessionID:))
    }

    private static func bringForward(_ session: ClaudeSession) async -> Bool {
        if let url = desktopURL(of: session) { return NSWorkspace.shared.open(url) }
        guard let pid = session.pid, let app = hostApp(of: pid), let appURL = app.bundleURL else { return false }

        if session.surface == .vscode, let cwd = session.cwd {
            let folder = URL(filePath: cwd, directoryHint: .isDirectory)
            let opened = try? await NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: .init())
            if opened != nil { return true }
        }
        if let bundleID = app.bundleIdentifier,
            let script = TerminalFocusScript.script(
                bundleID: bundleID, tty: ProcessTable.terminalPath(of: pid), workingDirectory: session.cwd,
                title: session.title),
            await run(script)
        {
            return true
        }
        // Through Launch Services: an app that isn't active itself, like Sidelight behind its panel, can't hand
        // activation to another app directly.
        return (try? await NSWorkspace.shared.openApplication(at: appURL, configuration: .init())) != nil
    }

    /// The app the process runs in: the nearest of the processes that started it that's an app with a Dock icon.
    /// `nil` for processes outside any app, such as those in a tmux session.
    private static func hostApp(of pid: Int32) -> NSRunningApplication? {
        ProcessTable.ancestry(of: pid).lazy
            .compactMap(NSRunningApplication.init(processIdentifier:))
            .first { $0.activationPolicy == .regular }
    }

    /// Runs the script in `osascript`, so a slow app or the permission prompt never blocks the panel.
    private static func run(_ script: String) async -> Bool {
        let output = await ProcessRunner.output(of: URL(filePath: "/usr/bin/osascript"), arguments: ["-e", script])
        let result = output.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        if result != "ok" { Log.claudeSessions.info("Couldn't find the session's terminal by script") }
        return result == "ok"
    }
}
