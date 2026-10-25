import Foundation

/// How long the Awake widget keeps the Mac awake, as its menu offers.
public enum AwakeChoice: Hashable, Sendable {
    case minutes(Int)
    case indefinitely

    /// What the menu lists, in order.
    public static let presets: [AwakeChoice] = [15, 30, 60, 120, 240].map(AwakeChoice.minutes) + [.indefinitely]

    /// `For 15 Minutes`, `For 1 Hour`, `For 2 Hours`, `Indefinitely`: Title Case, as menu items are.
    public var title: String {
        switch self {
        case .minutes(let minutes) where minutes >= 60 && minutes.isMultiple(of: 60):
            minutes == 60 ? "For 1 Hour" : "For \(minutes / 60) Hours"
        case .minutes(let minutes): minutes == 1 ? "For 1 Minute" : "For \(minutes) Minutes"
        case .indefinitely: "Indefinitely"
        }
    }
}

/// Whether the Mac is being kept awake, and until when.
public enum AwakeState: Hashable, Sendable {
    case off
    /// Until `ends`, always a whole minute.
    case timed(started: Date, ends: Date)
    /// Until someone stops it.
    case indefinite

    /// A session of `choice` from `now`. A timed one ends on a whole minute, rounded up, so the end time shown
    /// (`until 15:42`) is when it really ends.
    public static func started(_ choice: AwakeChoice, at now: Date) -> AwakeState {
        switch choice {
        case .indefinitely: .indefinite
        case .minutes(let minutes):
            .timed(started: now, ends: wholeMinute(after: now.addingTimeInterval(Double(minutes) * 60)))
        }
    }

    /// `date`, or the next whole minute if it isn't one.
    static func wholeMinute(after date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 60).rounded(.up) * 60)
    }

    public var isActive: Bool { self != .off }

    /// When a timed session ends; `nil` otherwise.
    public var ends: Date? {
        guard case .timed(_, let ends) = self else { return nil }
        return ends
    }

    /// Time left in a timed session, never negative; `nil` otherwise.
    public func remaining(at now: Date) -> TimeInterval? {
        ends.map { max(0, $0.timeIntervalSince(now)) }
    }

    /// The share of a timed session still to go, from 1 at the start to 0 at the end; `nil` otherwise.
    public func progress(at now: Date) -> Double? {
        guard case .timed(let started, let ends) = self, let remaining = remaining(at: now) else { return nil }
        let total = ends.timeIntervalSince(started)
        guard total > 0 else { return 0 }
        return min(1, max(0, remaining / total))
    }

    /// `42m`, `1h 5m`, `2h` left in a timed session, counting a started minute as a whole one so it never reads 0m
    /// while running; `nil` otherwise.
    public func shortRemaining(at now: Date) -> String? {
        guard let remaining = remaining(at: now) else { return nil }
        let minutes = max(1, Int((remaining / 60).rounded(.up)))
        let hours = minutes / 60
        return switch (hours, minutes % 60) {
        case (0, let minutes): "\(minutes)m"
        case (let hours, 0): "\(hours)h"
        case (let hours, let minutes): "\(hours)h \(minutes)m"
        }
    }
}

// MARK: - Saving

extension AwakeState: Codable {
    private enum CodingKeys: String, CodingKey { case mode, started, ends }
    private enum Mode: String, Codable { case off, timed, indefinite }

    /// Anything unreadable, such as a mode only a newer version knows, is off: the Mac then sleeps as usual, which is
    /// never a surprise.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch container.decodeLeniently(.mode, or: Mode.off) {
        case .off: self = .off
        case .indefinite: self = .indefinite
        case .timed:
            if let started = try? container.decode(Date.self, forKey: .started),
                let ends = try? container.decode(Date.self, forKey: .ends)
            {
                self = .timed(started: started, ends: ends)
            } else {
                self = .off
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .off: try container.encode(Mode.off, forKey: .mode)
        case .indefinite: try container.encode(Mode.indefinite, forKey: .mode)
        case .timed(let started, let ends):
            try container.encode(Mode.timed, forKey: .mode)
            try container.encode(started, forKey: .started)
            try container.encode(ends, forKey: .ends)
        }
    }

    /// What's left of this session at `now`, as after a relaunch or a sleep: a timed one that has ended is off.
    public func resumed(at now: Date) -> AwakeState {
        guard let ends, ends <= now else { return self }
        return .off
    }
}
