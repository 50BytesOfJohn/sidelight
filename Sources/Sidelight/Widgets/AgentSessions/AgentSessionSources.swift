import Foundation
import Observation
import SidelightCore

/// Every agent's sessions in one list, from the services that already follow each agent: the same ones the Claude
/// Code and Codex sessions widgets read, so nothing is watched twice. Nothing of its own runs; `AppController` runs
/// each service while a widget listing that agent is visible, and views reading through this redraw when any of
/// them changes.
@Observable
final class AgentSessionSources {
    let claudeCode: ClaudeSessionsService
    let codex: CodexSessionsService
    let cursor: CursorChatsService
    let openCode: OpenCodeSessionsService

    init(
        claudeCode: ClaudeSessionsService, codex: CodexSessionsService, cursor: CursorChatsService,
        openCode: OpenCodeSessionsService
    ) {
        self.claudeCode = claudeCode
        self.codex = codex
        self.cursor = cursor
        self.openCode = openCode
    }

    /// Whether an agent's sessions could be read.
    enum State: Equatable {
        /// Not read yet.
        case reading
        /// `open` sessions a process has open; `nil` for an agent that doesn't say.
        case found(open: Int?)
        case notFound
        /// Found, but in a version whose sessions this one can't read.
        case unsupported
        /// Found, but the last read failed. `isStale` when sessions read earlier are still listed.
        case unreadable(isStale: Bool)
    }

    func state(of provider: AgentProvider) -> State {
        switch provider {
        case .claudeCode:
            guard claudeCode.registryExists else { return .notFound }
            guard claudeCode.hasLoaded else { return .reading }
            return .found(open: claudeCode.sessions.count { $0.activity != .closed })
        case .codex:
            guard codex.hasLoaded else { return .reading }
            guard codex.codexFound else { return .notFound }
            return .found(open: codex.sessions.count { $0.pid != nil })
        case .cursor:
            guard cursor.hasLoaded else { return .reading }
            return switch cursor.availability {
            case .found: .found(open: nil)
            case .notFound: .notFound
            case .unsupported: .unsupported
            case .unreadable: .unreadable(isStale: !cursor.chats.isEmpty)
            }
        case .openCode:
            guard openCode.hasLoaded else { return .reading }
            return switch openCode.availability {
            case .found: .found(open: nil)
            case .notFound: .notFound
            case .unsupported: .unsupported
            case .unreadable: .unreadable(isStale: !openCode.sessions.isEmpty)
            }
        }
    }

    /// The sessions of `provider`, most urgent first.
    func sessions(of provider: AgentProvider, includesCodexExec: Bool) -> [AgentSession] {
        switch provider {
        case .claudeCode: claudeCode.sessions.map(AgentSession.init)
        case .codex: codex.sessions.filter { includesCodexExec || !$0.isExec }.map(AgentSession.init)
        case .cursor: cursor.chats.map(AgentSession.init)
        case .openCode: openCode.sessions.map(AgentSession.init)
        }
    }

    /// The sessions the widget lists, from every agent it shows, most urgent first, then newest first.
    func sessions(for settings: AgentSessionsSettings) -> [AgentSession] {
        AgentSession.merged(
            settings.providers.map { sessions(of: $0, includesCodexExec: settings.includesCodexExec) })
    }
}
