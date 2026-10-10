import Foundation

/// One plan rate-limit window, such as Codex's or Claude's 5-hour session or weekly limit.
public struct RateLimitWindow: Equatable, Sendable {
    public var usedPercent: Double
    public var resetsAt: Date?
    public var durationMinutes: Int?

    public init(usedPercent: Double, resetsAt: Date? = nil, durationMinutes: Int? = nil) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.durationMinutes = durationMinutes
    }
}

/// Whether a window's limit lasts until it resets, going by how fast it's been used so far.
public enum RateLimitPace: Equatable, Sendable {
    /// Too early in the window to tell, or its timing is unknown.
    case unknown
    /// At this rate the limit lasts until the window resets.
    case lasts
    /// At this rate the limit runs out at the given time, before the window resets.
    case runsOut(at: Date)
    /// The limit is used up until the window resets.
    case reached
}

extension RateLimitWindow {
    /// How much of a window has to have passed before ``pace(at:)`` forecasts: earlier, a single busy minute
    /// would read as running out.
    public static let minimumElapsedFractionForPace = 0.1

    public var duration: TimeInterval? { durationMinutes.map { TimeInterval($0) * 60 } }

    public var startsAt: Date? {
        guard let resetsAt, let duration else { return nil }
        return resetsAt.addingTimeInterval(-duration)
    }

    /// The share of the window's time that has passed at `now`, 0–1.
    public func elapsedFraction(at now: Date) -> Double? {
        guard let startsAt, let duration, duration > 0 else { return nil }
        return min(max(now.timeIntervalSince(startsAt) / duration, 0), 1)
    }

    /// Projects the usage so far at the same rate. The limit runs out before the reset exactly when more of it
    /// is used than of the window's time.
    public func pace(at now: Date) -> RateLimitPace {
        if usedPercent >= 100 { return .reached }
        guard let startsAt, let elapsed = elapsedFraction(at: now), elapsed >= Self.minimumElapsedFractionForPace
        else { return .unknown }
        guard usedPercent > 100 * elapsed else { return .lasts }
        return .runsOut(at: startsAt.addingTimeInterval(now.timeIntervalSince(startsAt) * 100 / usedPercent))
    }

    /// The window as it stands at `now`, for data captured earlier: once its reset has passed, usage starts
    /// again from zero. A window that resets on a fixed schedule (a weekly limit) moves on by whole windows;
    /// one that starts with the next request (a 5-hour session) has no known reset until then.
    public func current(at now: Date, resetsOnSchedule: Bool) -> RateLimitWindow {
        guard let resetsAt, resetsAt <= now else { return self }
        var window = RateLimitWindow(usedPercent: 0, durationMinutes: durationMinutes)
        if resetsOnSchedule, let duration, duration > 0 {
            let periods = (now.timeIntervalSince(resetsAt) / duration).rounded(.down) + 1
            window.resetsAt = resetsAt.addingTimeInterval(periods * duration)
        }
        return window
    }
}
