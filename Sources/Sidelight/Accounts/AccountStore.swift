import Foundation
import Observation
import SidelightCore
import os

/// Every account Sidelight can use, for Settings, the widgets' settings and the data services: the key accounts in the
/// configuration and the app sign-ins found on this Mac, each provider's default, and how each account is doing.
///
/// Adding, renaming and removing key accounts, choosing a default and replacing a key all go through here. Secrets
/// go to the ``AccountKeyring`` and never come back out of this store: only data services read them, from the
/// keyring. How an account is doing comes from the data services' own fetches; nothing here checks on a timer.
@Observable
final class AccountStore {
    /// How each account is doing, as the data service that uses it last found; missing until one has.
    private(set) var statuses: [AccountID: AccountStatus] = [:]
    /// App sign-ins whose app or CLI was found on this Mac, as their services last looked.
    private(set) var foundAppSignIns: Set<AccountID> = []
    /// App sign-ins signed in now, as their services last looked.
    private(set) var signedInAppSignIns: Set<AccountID> = []
    /// Secrets saved by versions before accounts are still moving to their accounts: until they have, a widget
    /// without an account waits rather than ask for one.
    var isMovingLegacySecrets = false

    @ObservationIgnored private let configurationStore: ConfigurationStore
    @ObservationIgnored private let keyring: AccountKeyring

    init(configuration: ConfigurationStore, keyring: AccountKeyring) {
        configurationStore = configuration
        self.keyring = keyring
    }

    private var configuration: AppConfiguration { configurationStore.configuration }

    // MARK: Reading

    /// `provider`'s key accounts in the order they were added, then its app sign-in.
    func accounts(of provider: AccountProvider) -> [Account] {
        configuration.keyAccounts(of: provider) + [provider.appSignIn].compactMap(\.self)
    }

    /// The accounts a widget at `provider` can choose from: its key accounts, and its app sign-in where the app was
    /// found, or it's the one in use.
    func choices(at provider: AccountProvider, using current: AccountID? = nil) -> [Account] {
        let keys = configuration.keyAccounts(of: provider)
        guard let signIn = provider.appSignIn else { return keys }
        let showsSignIn =
            !provider.acceptsKeys || foundAppSignIns.contains(signIn.id) || signedInAppSignIns.contains(signIn.id)
            || current == signIn.id || defaultAccount(for: provider).accountID == signIn.id
        return keys + (showsSignIn ? [signIn] : [])
    }

    func account(_ id: AccountID) -> Account? {
        configuration.account(id)
    }

    /// The account a widget naming `reference` uses (see ``AppConfiguration/resolveAccount(_:at:signedIn:)``).
    func resolve(_ reference: AccountID?, at provider: AccountProvider) -> AccountResolution {
        configuration.resolveAccount(reference, at: provider, signedIn: signedInAppSignIns)
    }

    /// The account `provider`'s widgets use when they name none.
    func defaultAccount(for provider: AccountProvider) -> AccountResolution {
        configuration.defaultAccount(for: provider, signedIn: signedInAppSignIns)
    }

    func status(of id: AccountID) -> AccountStatus? {
        statuses[id]
    }

    /// How many widgets (counting each Balance block) use `id`, by name or as the default.
    func uses(of id: AccountID) -> Int {
        configuration.uses(of: id, signedIn: signedInAppSignIns)
    }

    func suggestedName(for provider: AccountProvider) -> String {
        configuration.suggestedAccountName(for: provider)
    }

    // MARK: Changing

    /// Adds a key account at `provider` named `name`, with `secret` saved in the keychain first; returns it, or `nil`
    /// when the keychain couldn't save the secret. The caller checks the secret with the provider beforehand.
    ///
    /// Once a provider has a second account, the one its widgets used so far becomes the default, so they keep
    /// showing it.
    func add(at provider: AccountProvider, name: String, secret: String) async -> Account? {
        let account = Account.key(provider, name: Self.trimmed(name) ?? suggestedName(for: provider))
        guard await keyring.save(secret, for: account) else { return nil }
        let previous = defaultAccount(for: provider).accountID
        configurationStore.configuration.accounts.append(account)
        if configuration.defaultAccounts[provider] == nil, let previous,
            configuration.keyAccounts(of: provider).contains(where: { $0.id == previous })
        {
            configurationStore.configuration.defaultAccounts[provider] = previous
        }
        Log.accounts.info("Added a \(provider.rawValue, privacy: .public) account")
        return account
    }

    /// Renames the key account `id`. An empty name keeps the old one.
    func rename(_ id: AccountID, to name: String) {
        guard let name = Self.trimmed(name),
            let index = configuration.accounts.firstIndex(where: { $0.id == id })
        else { return }
        configurationStore.configuration.accounts[index].name = name
    }

    /// Makes `id` its provider's default account.
    func makeDefault(_ id: AccountID) {
        guard let account = account(id) else { return }
        configurationStore.configuration.defaultAccounts[account.provider] = id
    }

    /// Saves `secret` in place of the key account `id`'s; returns whether it was saved. What the old one fetched is
    /// forgotten. The caller checks the secret with the provider beforehand.
    func replaceSecret(of id: AccountID, with secret: String) async -> Bool {
        guard let account = configuration.accounts.first(where: { $0.id == id }) else { return false }
        guard await keyring.save(secret, for: account) else { return false }
        statuses[id] = nil
        Log.accounts.info("Replaced a \(account.provider.rawValue, privacy: .public) account's key")
        return true
    }

    /// Removes the key account `id`: from the configuration, where the widgets that named it go back to the default,
    /// and then its secret from the keychain. If the keychain can't delete it, nothing uses it again, since no account
    /// names it: that's only logged.
    func remove(_ id: AccountID) {
        guard let account = configuration.accounts.first(where: { $0.id == id }) else { return }
        configurationStore.configuration.removeAccount(id)
        statuses[id] = nil
        let keyring = keyring
        Task {
            if await !keyring.delete(id) {
                Log.accounts.error(
                    "Couldn't delete a removed \(account.provider.rawValue, privacy: .public) account's key")
            }
        }
        Log.accounts.info("Removed a \(account.provider.rawValue, privacy: .public) account")
    }

    /// Moves the secrets versions before accounts kept to their accounts, before any is read.
    func moveLegacySecrets(_ migration: LegacySecretMigration) {
        isMovingLegacySecrets = true
        let configuration = configurationStore
        let task = Task {
            await migration.run(on: configuration)
            isMovingLegacySecrets = false
        }
        keyring.waitFor(task)
    }

    // MARK: From the data services

    /// How `id` is doing, from a data service's fetch; `nil` once nothing tells.
    func report(_ status: AccountStatus?, for id: AccountID) {
        guard statuses[id] != status else { return }
        statuses[id] = status
    }

    /// Whether the app sign-in `id`'s app was found on this Mac, and whether it's signed in.
    func appSignIn(_ id: AccountID, isFound: Bool, isSignedIn: Bool) {
        if foundAppSignIns.contains(id) != isFound {
            if isFound { foundAppSignIns.insert(id) } else { foundAppSignIns.remove(id) }
        }
        if signedInAppSignIns.contains(id) != isSignedIn {
            if isSignedIn { signedInAppSignIns.insert(id) } else { signedInAppSignIns.remove(id) }
        }
    }

    private static func trimmed(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
