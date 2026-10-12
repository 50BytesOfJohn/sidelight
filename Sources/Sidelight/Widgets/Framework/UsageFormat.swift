import Foundation
import SidelightCore

extension UsageReading {
    var title: String {
        switch self {
        case .remaining: "What's left"
        case .used: "What's used"
        }
    }

    /// After a percentage: `66% left`.
    var suffix: String {
        switch self {
        case .remaining: "left"
        case .used: "used"
        }
    }
}

/// Text formats the usage widgets and their settings share.
enum UsageFormat {
    /// `14:20` today, `Fri 06:00` on another day.
    static func moment(_ date: Date, now: Date) -> String {
        Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// `14:20` today, `Oct 28` on another day.
    static func day(_ date: Date, now: Date) -> String {
        Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// `just now`, `3m ago`, `2h ago`.
    static func age(of date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60
            ? "just now" : "\(Formatting.countdownLeadingUnit(to: now, now: date)) ago"
    }

    /// `2 hours, 14 minutes`, for VoiceOver.
    static func spokenDuration(until date: Date, now: Date) -> String {
        let seconds = max(60, (date.timeIntervalSince(now) / 60).rounded() * 60)
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2))
    }

    /// Codex's plan identifiers as people know them: `plus` → `Plus`, `prolite` → `Pro Lite`. `nil` for `unknown`.
    static func planTitle(_ plan: String) -> String? {
        switch plan.lowercased() {
        case "", "unknown": nil
        case "prolite": "Pro Lite"
        case "promax": "Pro Max"
        case "edu": "Edu"
        default: plan.split(separator: "_").map(\.capitalized).joined(separator: " ")
        }
    }

    /// A credit balance (sent as a decimal string) as a whole number: `1,250`.
    static func credits(_ balance: String) -> String? {
        guard let value = Double(balance), value.isFinite else { return nil }
        return value.rounded(.down).formatted(.number.precision(.fractionLength(0)))
    }
}
