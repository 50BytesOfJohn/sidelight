import Foundation

/// An Awake widget's look. Both keep the same Mac awake; they differ only in how much room they take.
public enum AwakeStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The cup on a disc, with a ring of time left: a Control Center tile.
    case tile
    /// One short line with a hairline of time left, for panels that want it out of the way.
    case slim

    public var id: Self { self }
}

/// One Awake widget's own settings. What every Awake widget shares is in ``AwakeOptions``.
public struct AwakeSettings: Codable, Hashable, Sendable {
    public var style: AwakeStyle = .tile

    public init(style: AwakeStyle = .tile) {
        self.style = style
    }

    /// Released versions saved no settings for an Awake widget, so missing ones take their defaults, as does a
    /// style only a newer version knows.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = container.decodeLeniently(.style, or: AwakeSettings().style)
    }
}
