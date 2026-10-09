import Foundation

/// What's playing, as reported by `media-control stream`.
public struct NowPlayingState: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var playing: Bool?
    /// Raw image bytes (decoded from the payload's base64 `artworkData`).
    public var artworkData: Data?

    public init(
        title: String? = nil,
        artist: String? = nil,
        playing: Bool? = nil,
        artworkData: Data? = nil
    ) {
        self.title = title
        self.artist = artist
        self.playing = playing
        self.artworkData = artworkData
    }

    public var hasTrack: Bool { !(title ?? "").isEmpty }

    public var isPlaying: Bool { playing ?? false }

    public mutating func apply(_ update: NowPlayingUpdate) {
        if !update.isDiff { self = NowPlayingState() }
        update.title.apply(to: &title)
        update.artist.apply(to: &artist)
        update.playing.apply(to: &playing)
        update.artworkData.apply(to: &artworkData)
    }
}

/// One line of `media-control stream` output: `{"type": "data", "diff": true, "payload": {…}}`.
///
/// A full update (`diff: false`) replaces the state. In a diff, a missing key leaves the field unchanged and
/// `null` clears it.
public struct NowPlayingUpdate: Equatable, Sendable {
    public enum Change<Value: Equatable & Sendable>: Equatable, Sendable {
        case unchanged
        case removed
        case set(Value)

        func apply(to value: inout Value?) {
            switch self {
            case .unchanged: break
            case .removed: value = nil
            case .set(let newValue): value = newValue
            }
        }
    }

    public var isDiff: Bool
    public var title: Change<String> = .unchanged
    public var artist: Change<String> = .unchanged
    public var playing: Change<Bool> = .unchanged
    public var artworkData: Change<Data> = .unchanged

    public init(isDiff: Bool) {
        self.isDiff = isDiff
    }

    public static func decode(_ line: Data) -> NowPlayingUpdate? {
        try? JSONDecoder().decode(NowPlayingUpdate.self, from: line)
    }
}

extension NowPlayingUpdate: Decodable {
    private enum CodingKeys: String, CodingKey {
        case diff, payload
    }

    private enum PayloadKeys: String, CodingKey {
        case title, artist, playing, artworkData
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(isDiff: (try? container.decodeIfPresent(Bool.self, forKey: .diff)) ?? false)
        let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)

        func change<Value: Decodable>(_ key: PayloadKeys, as type: Value.Type) -> Change<Value> {
            guard payload.contains(key) else { return .unchanged }
            if (try? payload.decodeNil(forKey: key)) == true { return .removed }
            return (try? payload.decode(type, forKey: key)).map(Change.set) ?? .unchanged
        }

        title = change(.title, as: String.self)
        artist = change(.artist, as: String.self)
        playing = change(.playing, as: Bool.self)
        artworkData =
            switch change(.artworkData, as: String.self) {
            case .unchanged: .unchanged
            case .removed: .removed
            case .set(let base64): Data(base64Encoded: base64).map(Change.set) ?? .removed
            }
    }
}
