import Foundation

/// How Sidelight keeps itself up to date.
public struct UpdateSettings: Codable, Equatable, Sendable {
    /// Look for a new version in the background, about once a day.
    public var checksAutomatically: Bool
    /// Download and install new versions without asking. They take effect the next time Sidelight launches.
    public var installsAutomatically: Bool

    public init(checksAutomatically: Bool = true, installsAutomatically: Bool = false) {
        self.checksAutomatically = checksAutomatically
        self.installsAutomatically = installsAutomatically
    }
}
