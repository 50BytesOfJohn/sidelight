import Foundation

/// A service Sidelight connects to with an account.
public enum AccountProvider: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable, Sendable {
    case openRouter
    case railway
    case claudeCode
    case codex
    case cursor

    public var id: Self { self }

    /// `OpenRouter`, `Claude Code`…
    public var title: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .railway: "Railway"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    /// Whether someone can add accounts with a key or token typed into Sidelight.
    public var acceptsKeys: Bool {
        switch self {
        case .openRouter, .railway: true
        case .claudeCode, .codex, .cursor: false
        }
    }

    /// The sign-in another app or CLI owns, which Sidelight only reads; `nil` for a provider without one.
    public var appSignIn: Account? {
        switch self {
        case .openRouter: nil
        case .railway: Account(id: .railwayCLI, provider: self, name: "Railway CLI", kind: .appSignIn)
        case .claudeCode: Account(id: .claudeCodeApp, provider: self, name: "Claude Code", kind: .appSignIn)
        case .codex: Account(id: .codexApp, provider: self, name: "Codex", kind: .appSignIn)
        case .cursor: Account(id: .cursorApp, provider: self, name: "Cursor", kind: .appSignIn)
        }
    }
}

/// How Sidelight signs in to an account.
public enum AccountKind: String, Codable, Sendable {
    /// A key or token typed into Sidelight, kept in the Keychain under the account's ID.
    case key
    /// Another app's or CLI's own sign-in, which Sidelight only reads. Never saved in `config.json`.
    case appSignIn
}

/// Which account something uses. Key accounts have a UUID; app sign-ins a fixed ID for their provider, like
/// `railway.cli`, so a widget can name one without it being saved.
public struct AccountID: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: AccountID, rhs: AccountID) -> Bool { lhs.rawValue < rhs.rawValue }

    /// A new key account's ID.
    public static func newKey() -> AccountID {
        AccountID(rawValue: UUID().uuidString)
    }

    public static let railwayCLI = AccountID(rawValue: "railway.cli")
    public static let claudeCodeApp = AccountID(rawValue: "claudeCode.app")
    public static let codexApp = AccountID(rawValue: "codex.app")
    public static let cursorApp = AccountID(rawValue: "cursor.app")
}

/// One identity at one provider.
public struct Account: Codable, Hashable, Identifiable, Sendable {
    public let id: AccountID
    public let provider: AccountProvider
    /// What Sidelight calls it, to tell accounts apart. Someone can rename a key account.
    public var name: String
    public let kind: AccountKind

    public init(id: AccountID, provider: AccountProvider, name: String, kind: AccountKind) {
        self.id = id
        self.provider = provider
        self.name = name
        self.kind = kind
    }

    /// A new key account at `provider`.
    public static func key(_ provider: AccountProvider, name: String) -> Account {
        Account(id: .newKey(), provider: provider, name: name, kind: .key)
    }
}

/// How an account is doing, as the data service that uses it last found: never checked on a timer of its own.
public enum AccountStatus: Hashable, Sendable {
    case connected
    /// There's no sign-in to use: no key saved, or the app isn't signed in.
    case needsSignIn
    /// The provider no longer accepts the sign-in.
    case expired
    /// The last request failed for another reason, which this says.
    case failed(String)

    /// Only signing in again (or replacing the key) fixes it.
    public var needsSignIn: Bool {
        switch self {
        case .needsSignIn, .expired: true
        case .connected, .failed: false
        }
    }
}

/// Which account a widget uses, worked out from its account reference and the accounts there are.
public enum AccountResolution: Hashable, Sendable {
    case account(AccountID)
    /// The widget names an account that doesn't exist (any more). Another account is never used in its place.
    case notFound(AccountID)
    /// The provider has no account the widget could use.
    case noAccount
    /// The provider has several accounts, none of them the default, and the widget names none.
    case chooseAccount

    /// The account to use, when there is one.
    public var accountID: AccountID? {
        if case .account(let id) = self { id } else { nil }
    }
}

extension AppConfiguration {
    /// The key accounts at `provider`, in the order they were added.
    public func keyAccounts(of provider: AccountProvider) -> [Account] {
        accounts.filter { $0.provider == provider }
    }

    /// The key account `id`, or the app sign-in it names; `nil` when there's none.
    public func account(_ id: AccountID) -> Account? {
        accounts.first { $0.id == id }
            ?? AccountProvider.allCases.lazy.compactMap(\.appSignIn).first { $0.id == id }
    }

    /// The account a widget at `provider` uses when it names none: the default someone chose; for Railway without
    /// one, the Railway CLI while it's signed in; otherwise the provider's only key account; and a provider whose
    /// only account is an app sign-in uses that. `signedIn` holds the app sign-ins signed in now.
    public func defaultAccount(for provider: AccountProvider, signedIn: Set<AccountID> = []) -> AccountResolution {
        if let id = defaultAccounts[provider], exists(id, at: provider) { return .account(id) }
        let keys = keyAccounts(of: provider)
        if let signIn = provider.appSignIn?.id {
            if provider == .railway, signedIn.contains(signIn) { return .account(signIn) }
            if !provider.acceptsKeys { return .account(signIn) }
        }
        switch keys.count {
        case 0: return .noAccount
        case 1: return .account(keys[0].id)
        default: return .chooseAccount
        }
    }

    /// The account a widget at `provider` uses, given its account `reference`: the one it names, as long as it
    /// exists, or the default when it names none.
    public func resolveAccount(
        _ reference: AccountID?, at provider: AccountProvider, signedIn: Set<AccountID> = []
    ) -> AccountResolution {
        guard let reference else { return defaultAccount(for: provider, signedIn: signedIn) }
        return exists(reference, at: provider) ? .account(reference) : .notFound(reference)
    }

    /// Whether `id` is one of `provider`'s key accounts or its app sign-in.
    private func exists(_ id: AccountID, at provider: AccountProvider) -> Bool {
        provider.appSignIn?.id == id || accounts.contains { $0.id == id && $0.provider == provider }
    }

    /// A name for another key account at `provider`: `OpenRouter`, then `OpenRouter 2` and so on, one no account
    /// there has yet.
    public func suggestedAccountName(for provider: AccountProvider) -> String {
        let names = Set(keyAccounts(of: provider).map(\.name))
        guard names.contains(provider.title) else { return provider.title }
        var number = 2
        while names.contains("\(provider.title) \(number)") { number += 1 }
        return "\(provider.title) \(number)"
    }
}

// MARK: - References

extension AppConfiguration {
    /// How many widgets (counting each Balance block) name `id`.
    public func references(to id: AccountID) -> Int {
        widgets.reduce(0) { count, widget in
            switch widget.settings {
            case .openRouter(let settings): count + settings.allBalances.count { $0.options.account == id }
            case .railway(let settings): count + (settings.account == id ? 1 : 0)
            default: count
            }
        }
    }

    /// How many widgets (counting each Balance block) use `id`: those that name it, and if it's its provider's default,
    /// those that name none.
    public func uses(of id: AccountID, signedIn: Set<AccountID> = []) -> Int {
        guard let provider = account(id)?.provider else { return references(to: id) }
        let usesDefault = defaultAccount(for: provider, signedIn: signedIn) == .account(id)
        return widgets.reduce(0) { count, widget in
            switch widget.settings {
            case .openRouter(let settings) where provider == .openRouter:
                count
                    + settings.allBalances.count {
                        $0.options.account == id || usesDefault && $0.options.account == nil
                    }
            case .railway(let settings) where provider == .railway:
                count + (settings.account == id || usesDefault && settings.account == nil ? 1 : 0)
            default: count
            }
        }
    }

    /// Widgets and blocks that name `id` use their provider's default account instead.
    public mutating func forgetReferences(to id: AccountID) {
        for widget in widgets {
            switch widget.settings {
            case .openRouter(var settings):
                var changed = false
                for (block, var options) in settings.allBalances where options.account == id {
                    options.account = nil
                    settings.setBalanceOptions(options, for: block)
                    changed = true
                }
                if changed { updateWidget(widget.id) { $0.settings = .openRouter(settings) } }
            case .railway(var settings) where settings.account == id:
                settings.account = nil
                updateWidget(widget.id) { $0.settings = .railway(settings) }
            default:
                break
            }
        }
    }

    /// Removes the key account `id`, and the widgets that named it use the default. If it was the default and
    /// several accounts are left, the first of them is the default now, so widgets keep showing one.
    public mutating func removeAccount(_ id: AccountID) {
        accounts.removeAll { $0.id == id }
        for (provider, account) in defaultAccounts where account == id {
            let left = keyAccounts(of: provider)
            defaultAccounts[provider] = left.count > 1 ? left[0].id : nil
        }
        forgetReferences(to: id)
    }
}
