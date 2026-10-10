import Foundation
import os

/// Unified logging categories.
///
/// Stream with `log stream --level debug --predicate 'subsystem == "app.getsidelight.Sidelight"'`.
public enum Log {
    public static let subsystem = "app.getsidelight.Sidelight"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let configuration = Logger(subsystem: subsystem, category: "configuration")
    public static let avoidance = Logger(subsystem: subsystem, category: "avoidance")
    public static let codex = Logger(subsystem: subsystem, category: "codex")
    public static let claudeCode = Logger(subsystem: subsystem, category: "claude-code")
    public static let claudeSessions = Logger(subsystem: subsystem, category: "claude-sessions")
    public static let cursor = Logger(subsystem: subsystem, category: "cursor")
    public static let nowPlaying = Logger(subsystem: subsystem, category: "now-playing")
    public static let calendar = Logger(subsystem: subsystem, category: "calendar")
    public static let noodleComputer = Logger(subsystem: subsystem, category: "noodle-computer")
    public static let process = Logger(subsystem: subsystem, category: "process")
}
