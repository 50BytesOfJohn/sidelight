import Foundation

/// Compact, fixed-width-friendly formatting used throughout the panel.
public enum Formatting {
    /// `999`, `12K`, `4.5M`, `1.23B`.
    public static func compactCount(_ value: Int64) -> String {
        let number = Double(value)
        return switch abs(number) {
        case 1e9...: String(format: "%.2fB", number / 1e9)
        case 1e6...: String(format: "%.1fM", number / 1e6)
        case 1e3...: String(format: "%.0fK", number / 1e3)
        default: "\(value)"
        }
    }

    /// Time left until `date` with the two most significant units: `2d 3h`, `4h 5m`, `12m`; `—` when unknown.
    public static func countdown(to date: Date?, now: Date) -> String {
        guard let date else { return "—" }
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Only the most significant unit of ``countdown(to:now:)``: `2d`, `4h`, `12m`.
    public static func countdownLeadingUnit(to date: Date?, now: Date) -> String {
        countdown(to: date, now: now).split(separator: " ").first.map(String.init) ?? ""
    }

    /// Very short countdown for minimal layouts: `now`, `14m`, `2h`, or the weekday (`Tue`) beyond a day.
    public static func shortCountdown(to date: Date, now: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "now" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return date.formatted(Date.FormatStyle(locale: locale).weekday(.abbreviated))
    }
}

/// The digits a clock face shows for a given instant.
public struct ClockReading: Equatable, Sendable {
    public let hour: String
    public let minute: String
    public let second: String
    /// `AM`/`PM` in 12-hour mode, `nil` in 24-hour mode.
    public let period: String?
    /// Minutes since midnight; changes exactly when the displayed `hour:minute` changes.
    public let minuteOfDay: Int

    public init(date: Date, uses24HourTime: Bool, calendar: Calendar = .autoupdatingCurrent) {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour24 = components.hour ?? 0
        let minute = components.minute ?? 0
        if uses24HourTime {
            hour = String(format: "%02d", hour24)
            period = nil
        } else {
            hour = String(hour24 % 12 == 0 ? 12 : hour24 % 12)
            period = hour24 < 12 ? "AM" : "PM"
        }
        self.minute = String(format: "%02d", minute)
        second = String(format: "%02d", components.second ?? 0)
        minuteOfDay = hour24 * 60 + minute
    }
}

/// Where an analog clock's hands point for a given instant, as fractions of a turn clockwise from 12.
public struct ClockHands: Equatable, Sendable {
    /// Moves on with every minute, not only every hour.
    public let hour: Double
    /// Jumps once a minute, as the face redraws.
    public let minute: Double
    public let second: Double

    public init(date: Date, calendar: Calendar = .autoupdatingCurrent) {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let minute = Double(components.minute ?? 0)
        hour = (Double((components.hour ?? 0) % 12) + minute / 60) / 12
        self.minute = minute / 60
        second = Double(components.second ?? 0) / 60
    }
}
