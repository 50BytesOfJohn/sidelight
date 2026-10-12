import Foundation

/// The Agent sessions widget: every agent's sessions in one list. It reads the same services as the Claude Code and
/// Codex sessions widgets, so showing both costs nothing extra.
public struct AgentSessionsSettings: Codable, Hashable, Sendable {
    /// What the settings editor offers.
    public static let sessionCountRange = 1...10
    /// What the settings editor offers for ``recentHours``.
    public static let recentHourChoices = [1, 4, 12, 24]

    /// The agents listed, in ``AgentProvider/allCases`` order.
    public private(set) var providers: [AgentProvider] = AgentProvider.allCases
    /// Rows listed in the regular layout; compact lists fewer.
    public var sessionCount = 5
    /// Finished, idle and closed sessions stay listed this long. Sessions that are working or need the user always
    /// show.
    public var recentHours = 4
    /// Sessions run by `codex exec`, from scripts and CI. Codex's own session list leaves them out too.
    public var includesCodexExec = false

    public init(
        providers: some Sequence<AgentProvider> = AgentProvider.allCases, sessionCount: Int = 5, recentHours: Int = 4,
        includesCodexExec: Bool = false
    ) {
        self.providers = Self.ordered(providers)
        self.sessionCount = sessionCount
        self.recentHours = recentHours
        self.includesCodexExec = includesCodexExec
    }

    /// Missing options take their defaults, so settings saved before an option existed still load. Unknown agents
    /// are skipped rather than failing the whole configuration.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AgentSessionsSettings()
        if let names = try? container.decodeIfPresent([String].self, forKey: .providers) {
            providers = Self.ordered(names.compactMap(AgentProvider.init(rawValue:)))
        }
        sessionCount = container.decodeLeniently(.sessionCount, or: defaults.sessionCount).clamped(
            to: Self.sessionCountRange)
        recentHours = max(
            1, container.decodeLeniently(.recentHours, or: defaults.recentHours))
        includesCodexExec =
            container.decodeLeniently(.includesCodexExec, or: defaults.includesCodexExec)
    }

    public func includes(_ provider: AgentProvider) -> Bool { providers.contains(provider) }

    /// Adds or removes an agent, keeping the order fixed.
    public mutating func set(_ provider: AgentProvider, included: Bool) {
        providers = Self.ordered(included ? providers + [provider] : providers.filter { $0 != provider })
    }

    public var recentWindow: TimeInterval { TimeInterval(recentHours) * 60 * 60 }

    private static func ordered(_ providers: some Sequence<AgentProvider>) -> [AgentProvider] {
        let set = Set(providers)
        return AgentProvider.allCases.filter(set.contains)
    }
}
