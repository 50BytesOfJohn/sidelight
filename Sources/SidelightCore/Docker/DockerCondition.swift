import Foundation

/// What a container's state means to someone glancing at it: the one place that decides what's an issue, and what
/// counts as active. ``DockerSnapshot/condition(of:)`` works it out, since whether an exit is a crash depends on the
/// container's siblings.
public enum DockerCondition: Hashable, Sendable {
    case healthy
    /// Running, with no healthcheck.
    case running
    /// Running, its healthcheck not yet passed.
    case starting
    case unhealthy
    case restarting
    case paused
    case created
    case exited(code: Int)
    /// Exited with an error while the rest of its project kept running.
    case crashed(code: Int)
    case dead
    case removing
    case other(String)

    /// Something's wrong with it.
    public var isIssue: Bool {
        switch self {
        case .unhealthy, .restarting, .crashed, .dead: true
        default: false
        }
    }

    /// Running, paused, or worth looking at: what the Active list shows.
    public var isActive: Bool {
        switch self {
        case .healthy, .running, .starting, .paused: true
        default: isIssue
        }
    }

    /// Its running process is up, whatever its health.
    public var isRunning: Bool {
        switch self {
        case .healthy, .running, .starting, .unhealthy: true
        default: false
        }
    }

    /// How it reads in a summary of issues: `1 unhealthy`.
    public var issueTitle: String? {
        switch self {
        case .unhealthy: "unhealthy"
        case .restarting: "restarting"
        case .crashed: "crashed"
        case .dead: "dead"
        default: nil
        }
    }

    /// Higher is worse: an issue beats starting, which beats running.
    var severity: Int {
        switch self {
        case .dead: 7
        case .crashed: 6
        case .unhealthy: 5
        case .restarting: 4
        case .starting: 3
        case .healthy, .running: 2
        case .paused: 1
        case .created, .exited, .removing, .other: 0
        }
    }

    /// The condition of a container on its own, before its siblings are considered: an exit is never a crash here.
    init(_ container: DockerContainer) {
        self =
            switch container.state {
            case .running:
                switch container.health {
                case .none: .running
                case .starting: .starting
                case .healthy: .healthy
                case .unhealthy: .unhealthy
                }
            case .restarting: .restarting
            case .paused: .paused
            case .created: .created
            case .exited: .exited(code: container.exitCode)
            case .dead: .dead
            case .removing: .removing
            case .other(let status): .other(status)
            }
    }
}
