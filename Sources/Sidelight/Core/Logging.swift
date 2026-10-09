import Foundation
import os

/// Unified logging. View with Console.app or `log stream --predicate 'subsystem == "app.getsidelight.Sidelight"'`.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "app.getsidelight.Sidelight"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let config = Logger(subsystem: subsystem, category: "config")
    static let avoidance = Logger(subsystem: subsystem, category: "avoidance")
    static let agents = Logger(subsystem: subsystem, category: "agents")
}
