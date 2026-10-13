import Foundation

/// How often a widget's data is fetched while it's on screen: only when asked, or every so many minutes.
///
/// Stored in `config.json` as `"manual"` or a number of minutes (`60`).
public enum RefreshCadence: Hashable, Sendable {
    /// Fetched once when there's nothing to show yet, then only when someone asks.
    case manual
    case minutes(Int)

    public var minutes: Int? {
        if case .minutes(let minutes) = self { minutes } else { nil }
    }

    /// The more frequent of the two: what two widgets sharing one fetch need together.
    public func merged(with other: RefreshCadence) -> RefreshCadence {
        switch (self, other) {
        case (.manual, .manual): .manual
        case (.minutes(let minutes), .manual), (.manual, .minutes(let minutes)): .minutes(minutes)
        case (.minutes(let mine), .minutes(let theirs)): .minutes(min(mine, theirs))
        }
    }

    /// This cadence with a hand-edited interval moved into `range`.
    public func clamped(to range: ClosedRange<Int>) -> RefreshCadence {
        switch self {
        case .manual: .manual
        case .minutes(let minutes): .minutes(minutes.clamped(to: range))
        }
    }
}

extension RefreshCadence: Codable {
    private static let manualValue = "manual"

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let minutes = try? container.decode(Int.self) {
            self = .minutes(minutes)
            return
        }
        let string = try container.decode(String.self)
        guard string == Self.manualValue else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected \"manual\" or a number of minutes, got \(string)")
        }
        self = .manual
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .manual: try container.encode(Self.manualValue)
        case .minutes(let minutes): try container.encode(minutes)
        }
    }
}

extension Optional where Wrapped == RefreshCadence {
    /// Both demands together: `nil` means nobody needs it.
    public func merged(with other: RefreshCadence?) -> RefreshCadence? {
        switch (self, other) {
        case (nil, let cadence), (let cadence, nil): cadence
        case (let mine?, let theirs?): mine.merged(with: theirs)
        }
    }
}
