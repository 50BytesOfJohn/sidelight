import Foundation
import os

/// Unified logging categories.
///
/// Stream with `log stream --level debug --predicate 'subsystem == "app.getsidelight.Sidelight"'`.
public enum Log {
    public static let subsystem = "app.getsidelight.Sidelight"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let configuration = Logger(subsystem: subsystem, category: "configuration")
    public static let accounts = Logger(subsystem: subsystem, category: "accounts")
    public static let avoidance = Logger(subsystem: subsystem, category: "avoidance")
    public static let windowManager = Logger(subsystem: subsystem, category: "window-manager")
    /// Every window frame Sidelight writes goes through one place, and says so here.
    public static let placement = Logger(subsystem: subsystem, category: "placement")
    public static let codex = Logger(subsystem: subsystem, category: "codex")
    public static let claudeCode = Logger(subsystem: subsystem, category: "claude-code")
    public static let claudeSessions = Logger(subsystem: subsystem, category: "claude-sessions")
    public static let codexSessions = Logger(subsystem: subsystem, category: "codex-sessions")
    public static let cursor = Logger(subsystem: subsystem, category: "cursor")
    public static let openCode = Logger(subsystem: subsystem, category: "opencode")
    public static let nowPlaying = Logger(subsystem: subsystem, category: "now-playing")
    public static let calendar = Logger(subsystem: subsystem, category: "calendar")
    public static let noodleComputer = Logger(subsystem: subsystem, category: "noodle-computer")
    public static let railway = Logger(subsystem: subsystem, category: "railway")
    public static let openRouter = Logger(subsystem: subsystem, category: "openrouter")
    /// Organization names, model AIRs and key names only at the debug level.
    public static let runware = Logger(subsystem: subsystem, category: "runware")
    public static let details = Logger(subsystem: subsystem, category: "details")
    /// Never logs what was stashed: only that something was, and why something wasn't.
    public static let stash = Logger(subsystem: subsystem, category: "stash")
    public static let awake = Logger(subsystem: subsystem, category: "awake")
    public static let battery = Logger(subsystem: subsystem, category: "battery")
    /// Container names and ports only at the debug level: they can be private project names.
    public static let docker = Logger(subsystem: subsystem, category: "docker")
    /// App paths only at the debug level: they can name private projects.
    public static let appLauncher = Logger(subsystem: subsystem, category: "app-launcher")
    public static let process = Logger(subsystem: subsystem, category: "process")
}
