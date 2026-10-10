import Foundation

/// Ways back into a Claude Code session from outside it.
public enum ClaudeSessionLinks {
    /// Opens the session in the Claude desktop app, running or not: the link its own Dock menu uses. The app ignores
    /// IDs that don't look like its own.
    public static func desktopURL(sessionID: String) -> URL? {
        guard sessionID.wholeMatch(of: /local_[A-Za-z0-9-]{1,64}/) != nil else { return nil }
        return URL(string: "claude://code/continue?session=\(sessionID)")
    }

    /// A shell command that picks the session up again in its folder: `cd '/code/app' && claude --resume <id>`.
    public static func resumeCommand(sessionID: String, cwd: String?) -> String {
        let resume = "claude --resume \(shellQuoted(sessionID))"
        guard let cwd, !cwd.isEmpty else { return resume }
        return "cd \(shellQuoted(cwd)) && \(resume)"
    }

    private static func shellQuoted(_ text: String) -> String {
        guard text.contains(where: { !($0.isASCII && ($0.isLetter || $0.isNumber || "-_./".contains($0))) }) else {
            return text
        }
        return "'" + text.replacing("'", with: #"'\''"#) + "'"
    }
}

/// AppleScript that brings the terminal running a process to the front, in terminal apps that let a script find it.
/// Each script returns `ok` when it found the terminal.
public enum TerminalFocusScript {
    public static let terminalBundleID = "com.apple.Terminal"
    public static let iTermBundleID = "com.googlecode.iterm2"
    public static let ghosttyBundleID = "com.mitchellh.ghostty"

    /// The script for the app with `bundleID`; `nil` when it can't be scripted to find the terminal with what's known.
    ///
    /// Terminal and iTerm2 tell their tabs apart by `tty`, exactly. Ghostty only knows each terminal's working
    /// directory and title, so it picks the terminal in `workingDirectory` whose title mentions `title`, or else the
    /// first one there.
    public static func script(bundleID: String, tty: String?, workingDirectory: String?, title: String) -> String? {
        switch bundleID {
        case terminalBundleID:
            guard let tty else { return nil }
            return """
                tell application id "\(terminalBundleID)"
                    repeat with aWindow in windows
                        repeat with aTab in tabs of aWindow
                            if tty of aTab is \(literal(tty)) then
                                set selected of aTab to true
                                set index of aWindow to 1
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end tell
                return "missing"
                """
        case iTermBundleID:
            guard let tty else { return nil }
            return """
                tell application id "\(iTermBundleID)"
                    repeat with aWindow in windows
                        repeat with aTab in tabs of aWindow
                            repeat with aSession in sessions of aTab
                                if tty of aSession is \(literal(tty)) then
                                    select aWindow
                                    tell aTab to select
                                    tell aSession to select
                                    activate
                                    return "ok"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return "missing"
                """
        case ghosttyBundleID:
            guard let workingDirectory else { return nil }
            return """
                tell application id "\(ghosttyBundleID)"
                    set candidates to every terminal whose working directory is \(literal(workingDirectory))
                    if (count of candidates) is 0 then return "missing"
                    set chosen to item 1 of candidates
                    repeat with aTerminal in candidates
                        if name of aTerminal contains \(literal(title)) then
                            set chosen to aTerminal
                            exit repeat
                        end if
                    end repeat
                    focus chosen
                    activate
                    return "ok"
                end tell
                """
        default:
            return nil
        }
    }

    /// `text` as an AppleScript string literal.
    static func literal(_ text: String) -> String {
        let escaped = text.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
            .replacing("\n", with: " ").replacing("\r", with: " ")
        return "\"\(escaped)\""
    }
}
