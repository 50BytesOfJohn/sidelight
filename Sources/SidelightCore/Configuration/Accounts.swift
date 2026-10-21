import Foundation

/// A service Sidelight connects to with an account.
public enum AccountProvider: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable, Sendable {
    case openRouter
    case railway
    case claudeCode
    case codex
    case cursor
    case runware

    public var id: Self { self }

    /// `OpenRouter`, `Claude Code`…
    public var title: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .railway: "Railway"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .runware: "Runware"
        }
    }

    /// Whether someone can add accounts with a key or token typed into Sidelight.
    public var acceptsKeys: Bool {
        switch self {
        case .openRouter, .railway, .runware: true
        case .claudeCode, .codex, .cursor: false
        }
    }

    /// Whether its app keeps more accounts signed in, each in a folder of its own, that Sidelight can add as app
    /// profiles.
    public var acceptsAppProfiles: Bool {
        switch self {
        case .claudeCode: true
        case .openRouter, .railway, .codex, .cursor, .runware: false
        }
    }

    /// Whether someone can add accounts here, of either kind.
    public var canAddAccounts: Bool { acceptsKeys || acceptsAppProfiles }

    /// The sign-in another app or CLI owns, which Sidelight only reads; `nil` for a provider without one.
    public var appSignIn: Account? {
        switch self {
        case .openRouter: nil
        case .railway: Account(id: .railwayCLI, provider: self, name: "Railway CLI", kind: .appSignIn)
        case .claudeCode: Account(id: .claudeCodeApp, provider: self, name: "Claude Code", kind: .appSignIn)
        case .codex: Account(id: .codexApp, provider: self, name: "Codex", kind: .appSignIn)
        case .cursor: Account(id: .cursorApp, provider: self, name: "Cursor", kind: .appSignIn)
        case .runware: Account(id: .runwareCLI, provider: self, name: "Runware CLI", kind: .appSignIn)
        }
    }

    /// Whether its app sign-in, while signed in, is the default for widgets that name no account, ahead of a single
    /// key account: its CLI is how most people sign in to it. A default someone chose always comes first.
    public var prefersSignedInAppSignIn: Bool {
        switch self {
        case .railway, .runware: true
        case .openRouter, .claudeCode, .codex, .cursor: false
        }
    }
}

/// How Sidelight signs in to an account.
public enum AccountKind: String, Codable, Sendable {
    /// A key or token typed into Sidelight, kept in the Keychain under the account's ID.
    case key
    /// Another app's or CLI's own sign-in, which Sidelight only reads. Never saved in `config.json`.
    case appSignIn
    /// Another of the app's sign-ins, which it keeps in a folder of its own (Claude Code's `CLAUDE_CONFIG_DIR`).
    /// Sidelight saves the folder, not the sign-in: the app signs in and keeps it, and Sidelight only reads it.
    case appProfile
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

    /// A new ID for an account saved in `config.json`.
    public static func newKey() -> AccountID {
        AccountID(rawValue: UUID().uuidString)
    }

    public static let railwayCLI = AccountID(rawValue: "railway.cli")
    public static let claudeCodeApp = AccountID(rawValue: "claudeCode.app")
    public static let codexApp = AccountID(rawValue: "codex.app")
    public static let cursorApp = AccountID(rawValue: "cursor.app")
    public static let runwareCLI = AccountID(rawValue: "runware.cli")
}

/// One identity at one provider.
public struct Account: Codable, Hashable, Identifiable, Sendable {
    public let id: AccountID
    public let provider: AccountProvider
    /// What Sidelight calls it, to tell accounts apart. Someone can rename the accounts saved in `config.json`.
    public var name: String
    public let kind: AccountKind
    /// Where an app profile's app keeps its sign-in, exactly as the app is given it; `nil` for other kinds.
    public let folder: String?

    public init(id: AccountID, provider: AccountProvider, name: String, kind: AccountKind, folder: String? = nil) {
        self.id = id
        self.provider = provider
        self.name = name
        self.kind = kind
        self.folder = folder
    }

    /// A new key account at `provider`.
    public static func key(_ provider: AccountProvider, name: String) -> Account {
        Account(id: .newKey(), provider: provider, name: name, kind: .key)
    }

    /// A new app profile at `provider`, signed in to in `folder`.
    public static func appProfile(_ provider: AccountProvider, name: String, folder: String) -> Account {
        Account(id: .newKey(), provider: provider, name: name, kind: .appProfile, folder: folder)
    }

    /// Whether it's saved in `config.json`, where someone can rename and remove it: a key account or an app profile.
    public var isSaved: Bool { kind != .appSignIn }

    /// Whether `config.json` can hold it: a key account, or an app profile with a folder at a provider that has them.
    /// App sign-ins are found, never saved.
    var isWellFormed: Bool {
        switch kind {
        case .key: true
        case .appProfile: provider.acceptsAppProfiles && folder?.isEmpty == false
        case .appSignIn: false
        }
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
    /// The accounts saved at `provider` (key accounts and app profiles), in the order they were added.
    public func savedAccounts(of provider: AccountProvider) -> [Account] {
        accounts.filter { $0.provider == provider }
    }

    /// The saved account `id`, or the app sign-in it names; `nil` when there's none.
    public func account(_ id: AccountID) -> Account? {
        accounts.first { $0.id == id }
            ?? AccountProvider.allCases.lazy.compactMap(\.appSignIn).first { $0.id == id }
    }

    /// The account a widget at `provider` uses when it names none: the default someone chose; for Railway without
    /// one, the provider's CLI while it's signed in, for providers that prefer it (Railway, Runware); otherwise the provider's only key account; and a provider that
    /// takes no keys uses its app sign-in, whatever app profiles it has. `signedIn` holds the app sign-ins signed in
    /// now.
    public func defaultAccount(for provider: AccountProvider, signedIn: Set<AccountID> = []) -> AccountResolution {
        if let id = defaultAccounts[provider], exists(id, at: provider) { return .account(id) }
        let keys = savedAccounts(of: provider)
        if let signIn = provider.appSignIn?.id {
            if provider.prefersSignedInAppSignIn, signedIn.contains(signIn) { return .account(signIn) }
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

    /// Whether `id` is one of `provider`'s saved accounts or its app sign-in.
    private func exists(_ id: AccountID, at provider: AccountProvider) -> Bool {
        provider.appSignIn?.id == id || accounts.contains { $0.id == id && $0.provider == provider }
    }

    /// A name for another account at `provider`: `OpenRouter`, then `OpenRouter 2` and so on, one no account there
    /// has yet, its app sign-in included.
    public func suggestedAccountName(for provider: AccountProvider) -> String {
        let names = Set((savedAccounts(of: provider) + [provider.appSignIn].compactMap(\.self)).map(\.name))
        guard names.contains(provider.title) else { return provider.title }
        var number = 2
        while names.contains("\(provider.title) \(number)") { number += 1 }
        return "\(provider.title) \(number)"
    }
}

// MARK: - References

extension AppConfiguration {
    /// How many widgets name `id`, counting each block that names an account.
    public func references(to id: AccountID) -> Int {
        widgets.reduce(0) { count, widget in count + widget.settings.accountReferences.count { $0.account == id } }
    }

    /// How many widgets use `id`, counting each block that names an account: those that name it, and if it's its
    /// provider's default, those that name none.
    public func uses(of id: AccountID, signedIn: Set<AccountID> = []) -> Int {
        guard let provider = account(id)?.provider else { return references(to: id) }
        let usesDefault = defaultAccount(for: provider, signedIn: signedIn) == .account(id)
        return widgets.reduce(0) { count, widget in
            count
                + widget.settings.accountReferences.count { reference in
                    reference.provider == provider
                        && (reference.account == id || usesDefault && reference.account == nil)
                }
        }
    }

    /// Widgets and blocks that name `id` use their provider's default account instead.
    public mutating func forgetReferences(to id: AccountID) {
        for widget in widgets {
            var settings = widget.settings
            if settings.forgetAccount(id) { updateWidget(widget.id) { $0.settings = settings } }
        }
    }

    /// Removes the saved account `id`, and the widgets that named it use the default. If it was the default and
    /// several accounts are left, the first of them is the default now, so widgets keep showing one.
    public mutating func removeAccount(_ id: AccountID) {
        accounts.removeAll { $0.id == id }
        for (provider, account) in defaultAccounts where account == id {
            let left = savedAccounts(of: provider)
            // A provider that takes no keys goes back to its app sign-in.
            defaultAccounts[provider] = provider.acceptsKeys && left.count > 1 ? left[0].id : nil
        }
        forgetReferences(to: id)
    }
}

extension WidgetSettings {
    /// Each account reference the widget saves, one per block that shows an account, hidden blocks included: `nil`
    /// for its provider's default.
    public var accountReferences: [(provider: AccountProvider, account: AccountID?)] {
        switch self {
        case .openRouter(let settings): settings.allBalances.map { (.openRouter, $0.options.account) }
        case .railway(let settings): [(.railway, settings.account)]
        case .runware(let settings): [(.runware, settings.account)]
        case .claudeCode(let settings): [(.claudeCode, settings.account)]
        case .aiUsage(let settings): settings.accountReferences(shownOnly: false)
        case .clock, .codex, .cursor, .calendar, .nowPlaying, .claudeSessions, .codexSessions, .system,
            .noodleComputer, .agentSessions, .stash, .awake, .docker, .appLauncher, .battery:
            []
        }
    }

    /// Every reference to `id` names none instead, so its provider's default is used; returns whether one did.
    public mutating func forgetAccount(_ id: AccountID) -> Bool {
        switch self {
        case .openRouter(var settings):
            let named = settings.allBalances.filter { $0.options.account == id }
            for (block, var options) in named {
                options.account = nil
                settings.setBalanceOptions(options, for: block)
            }
            self = .openRouter(settings)
            return !named.isEmpty
        case .railway(var settings) where settings.account == id:
            settings.account = nil
            self = .railway(settings)
        case .claudeCode(var settings) where settings.account == id:
            settings.account = nil
            self = .claudeCode(settings)
        case .runware(var settings) where settings.account == id:
            settings.account = nil
            self = .runware(settings)
        case .aiUsage(var settings):
            let didForget = settings.forgetAccount(id)
            self = .aiUsage(settings)
            return didForget
        default:
            return false
        }
        return true
    }
}
