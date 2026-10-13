import Foundation

/// When to try a failed fetch again on its own.
public enum RetryAdvice: Equatable, Sendable {
    /// After the usual wait, longer after each failure in a row.
    case backoff
    /// Not before this moment, as the provider asked, and backing off as usual after it.
    case notBefore(Date)
    /// Only when someone asks: trying again can't help until something changes, like the credential.
    case onRequest
}

/// The `Retry-After` header of a response, which says how long to wait before asking again.
public enum RetryAfter {
    /// Waits longer than this are cut short, so a mistaken header can't stop fetching for days.
    public static let maximumWait: TimeInterval = 6 * 60 * 60

    /// The moment the header asks to wait until: it can give seconds (`120`) or an HTTP date. Header names are
    /// matched in any case. `nil` without a header, or with one that can't be read.
    public static func date(in headers: [String: String], now: Date) -> Date? {
        guard let value = headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame })?.value
        else { return nil }
        let text = value.trimmingCharacters(in: .whitespaces)
        if let seconds = Int(text) {
            guard seconds >= 0 else { return nil }
            return now.addingTimeInterval(min(TimeInterval(seconds), maximumWait))
        }
        guard let date = httpDate(text) else { return nil }
        return min(max(date, now), now.addingTimeInterval(maximumWait))
    }

    /// `Sun, 06 Nov 1994 08:49:37 GMT`, the format HTTP requires.
    private static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}
