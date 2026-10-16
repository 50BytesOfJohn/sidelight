import Foundation

/// What every Awake widget shares, as there's one Mac to keep awake. Only the option is saved: a session keeping it
/// awake lasts until Sidelight quits.
public struct AwakeOptions: Codable, Hashable, Sendable {
    /// Keep the screen on too, rather than letting it dim and lock as usual while the Mac stays awake.
    public var keepsDisplayOn = false

    public init(keepsDisplayOn: Bool = false) {
        self.keepsDisplayOn = keepsDisplayOn
    }

    /// Missing options take their defaults, as does one that can't be read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keepsDisplayOn = container.decodeLeniently(.keepsDisplayOn, or: AwakeOptions().keepsDisplayOn)
    }
}
