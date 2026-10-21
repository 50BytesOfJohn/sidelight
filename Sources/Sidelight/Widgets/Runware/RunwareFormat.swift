import Foundation
import SidelightCore

extension RunwareProblem {
    var title: String {
        switch self {
        case .noKey: "No API key"
        case .cliNotSignedIn: "Runware CLI not signed in"
        case .cliConfigUnreadable: "Can't read the Runware CLI's settings"
        case .invalidKey: "Runware doesn't accept the key"
        case .notPermitted: "The key may not read this"
        case .rateLimited: "Runware asked to wait"
        case .unavailable: "Runware is having trouble"
        case .badRequest: "Runware turned the request down"
        case .unreadable: "Unexpected answer from Runware"
        case .tooLarge: "Unexpectedly large answer"
        case .unreachable: "Can't reach Runware"
        case .keychain: "Can't read the key from the keychain"
        }
    }

    var advice: String {
        switch self {
        case .noKey:
            "Replace the account's key in Settings, under Accounts."
        case .cliNotSignedIn:
            "Run runware auth login, or add an API key in Settings, under Accounts."
        case .cliConfigUnreadable:
            "Run runware auth login again, or add an API key in Settings, under Accounts."
        case .invalidKey:
            "The key may have been deleted or disabled. Replace it in Settings, under Accounts."
        case .notPermitted:
            "The key's permissions don't cover this. Check it in Runware, then replace it in Settings, under Accounts."
        case .rateLimited:
            "Sidelight tries again once Runware allows it."
        case .unavailable(let status):
            "Status \(status). Sidelight tries again in a while."
        case .badRequest(let code, let message):
            message ?? code.map { "Runware said \($0)." } ?? "Asking again won't help; this may need a newer Sidelight."
        case .unreadable:
            "Nothing is shown that it can't vouch for. Sidelight tries again in a while."
        case .tooLarge:
            "The answer was far larger than these ever are, so it wasn't read."
        case .unreachable:
            "Check your connection. Sidelight tries again in a while."
        case .keychain:
            "The keychain may be locked. Sidelight tries again in a while."
        }
    }

    /// How the account is doing, when it's this.
    var accountStatus: AccountStatus? {
        switch self {
        case .noKey, .cliNotSignedIn: .needsSignIn
        case .invalidKey, .notPermitted: .expired
        default: .failed(title)
        }
    }

    /// Fixed only by saving a key again, or signing the CLI in: Sidelight doesn't ask Runware again on its own.
    var needsKey: Bool {
        switch self {
        case .noKey, .cliNotSignedIn, .cliConfigUnreadable, .invalidKey, .notPermitted: true
        default: false
        }
    }
}

extension RunwarePreset {
    var title: String {
        switch self {
        case .overview: "Overview"
        case .balance: "Balance"
        case .everything: "Everything"
        }
    }
}

extension RunwareChartMetric {
    var title: String {
        switch self {
        case .spend: "Spending"
        case .requests: "Requests"
        }
    }
}

extension RunwareSettings {
    /// The Widgets window's one-line description: `Overview · every 5 minutes`.
    var layoutSummary: String {
        let shown = blocks.shownBlocks.count
        let layout = preset?.title ?? (shown == 1 ? "1 block" : "\(shown) blocks")
        return "\(layout) · \(refresh.minutes.map { "every \($0) minutes" } ?? "manual")"
    }
}

/// How Runware's numbers read in Sidelight.
enum RunwareFormat {
    /// `$2,450.75`; with `abbreviated`, `$12.4K` from ten thousand up, for the smallest sizes.
    static func money(_ value: Decimal, currency: String, abbreviated: Bool = false) -> String {
        let style = Decimal.FormatStyle.Currency(code: currency)
        if abbreviated, abs(value) >= 10_000 {
            return value.formatted(style.notation(.compactName).precision(.fractionLength(0...1)))
        }
        return value.formatted(style.precision(.fractionLength(2)))
    }

    /// A day's or a model's spend: like ``money(_:currency:abbreviated:)``, but `<$0.01` for less than a cent, so a
    /// tiny amount doesn't read as nothing.
    static func amount(_ value: Decimal, currency: String) -> String {
        guard value > 0, value < Decimal(sign: .plus, exponent: -2, significand: 1) else {
            return money(value, currency: currency)
        }
        return "<" + money(Decimal(sign: .plus, exponent: -2, significand: 1), currency: currency)
    }

    /// `1,850 requests`, `1 request`.
    static func requests(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "request" : "requests")"
    }

    /// `Mon 20 Oct`, for a UTC day.
    static func day(_ day: UTCDay) -> String {
        day.start.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.abbreviated).day().month(.abbreviated))
    }

    /// `Oct 20`, for a UTC day.
    static func shortDay(_ day: UTCDay) -> String {
        day.start.formatted(Date.FormatStyle(timeZone: .gmt).month(.abbreviated).day())
    }

    /// Where someone sees each request: Runware's dashboard.
    static let dashboard = URL(string: "https://my.runware.ai/")!
}

extension RunwareBalance {
    /// `Balance $2,450.75, plus $120.00 free credits`.
    var accessibilityText: String {
        var text = "Balance \(RunwareFormat.money(amount, currency: currency))"
        if let freeBalance, freeBalance > 0 {
            text += ", plus \(RunwareFormat.money(freeBalance, currency: currency)) free credits"
        }
        return text
    }
}
