import AppKit
import SidelightCore
import os

/// Brings the app a coding agent's process runs in to the front, at the session where it can:
///
/// - Terminal, iTerm2 and Ghostty are asked (AppleScript) for the exact tab, by its tty or its folder and title.
///   macOS asks once per app whether Sidelight may do this; without it, the app just comes forward.
/// - VS Code and its forks reopen the session's folder, which focuses the window that has it.
/// - Any other app (another terminal, an app driving the agent) comes forward.
enum SessionHost {
    /// The app the process runs in: the nearest of the processes that started it that's an app with a Dock icon.
    /// `nil` for processes outside any app, such as those in a tmux session.
    static func app(of pid: Int32) -> NSRunningApplication? {
        ProcessTable.ancestry(of: pid).lazy
            .compactMap(NSRunningApplication.init(processIdentifier:))
            .first { $0.activationPolicy == .regular }
    }

    /// Brings `app` forward at the session `pid` runs: `opensFolder` reopens `cwd` in it, as editors want.
    static func bringForward(
        _ app: NSRunningApplication, pid: Int32, cwd: String?, title: String, opensFolder: Bool, log: Logger
    ) async -> Bool {
        guard let appURL = app.bundleURL else { return false }
        if opensFolder, let cwd {
            let folder = URL(filePath: cwd, directoryHint: .isDirectory)
            let opened = try? await NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: .init())
            if opened != nil { return true }
        }
        if let bundleID = app.bundleIdentifier,
            let script = TerminalFocusScript.script(
                bundleID: bundleID, tty: ProcessTable.terminalPath(of: pid), workingDirectory: cwd, title: title),
            await run(script, log: log)
        {
            return true
        }
        // Through Launch Services: an app that isn't active itself, like Sidelight behind its panel, can't hand
        // activation to another app directly.
        return (try? await NSWorkspace.shared.openApplication(at: appURL, configuration: .init())) != nil
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Runs the script in `osascript`, so a slow app or the permission prompt never blocks the panel.
    private static func run(_ script: String, log: Logger) async -> Bool {
        let output = await ProcessRunner.output(of: URL(filePath: "/usr/bin/osascript"), arguments: ["-e", script])
        let result = output.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        if result != "ok" { log.info("Couldn't find the session's terminal by script") }
        return result == "ok"
    }
}
