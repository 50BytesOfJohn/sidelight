import Foundation

/// Timing shared by widgets that fetch plan usage from a provider on a timer.
public enum UsageRefresh {
    /// After a failure, every further one in a row doubles the wait, up to `maximum` (or the interval itself, if
    /// that's longer).
    public static func retryDelay(interval: Duration, consecutiveFailures: Int, maximum: Duration) -> Duration {
        guard consecutiveFailures > 0 else { return interval }
        let backedOff = interval * (1 << min(consecutiveFailures, 10))
        return min(backedOff, max(interval, maximum))
    }
}
