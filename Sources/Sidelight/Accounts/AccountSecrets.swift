import Foundation
import SidelightCore
import os

/// Where every key account's secret is kept: a keychain item of Sidelight's own for each, under the account's ID.
/// Each call runs off the main actor. Nothing is ever read from other apps, shells or files here: app sign-ins are
/// read by their own services.
nonisolated struct AccountSecrets: Sendable {
    var lookUp: @Sendable (AccountID) async -> KeychainLookup
    /// Saves the secret for the account, replacing any saved before; returns whether it was saved.
    var save: @Sendable (String, Account) async -> Bool
    /// Returns whether nothing is saved for the account any more: deleted, or there was nothing.
    var delete: @Sendable (AccountID) async -> Bool

    static let defaultKeychainService = "app.getsidelight.Sidelight.accounts"

    static let keychain = AccountSecrets.keychain(service: defaultKeychainService)

    /// The keychain items under `service`, so a trial run's secrets stay apart from the real ones.
    static func keychain(service: String) -> AccountSecrets {
        @Sendable func item(_ id: AccountID, label: String = "") -> KeychainItem {
            KeychainItem(service: service, account: id.rawValue, label: label)
        }
        return AccountSecrets(
            lookUp: { await item($0).lookUp() },
            save: { secret, account in
                await item(account.id, label: "Sidelight: \(account.provider.title) key").save(secret)
            },
            delete: { await item($0).delete() })
    }

    /// Secrets kept in memory only, starting with `saved`, as a test might use.
    static func memory(_ saved: [AccountID: String] = [:]) -> AccountSecrets {
        let secrets = OSAllocatedUnfairLock(initialState: saved)
        return AccountSecrets(
            lookUp: { id in secrets.withLock { $0[id] }.map(KeychainLookup.found) ?? .missing },
            save: { secret, account in
                secrets.withLock { $0[account.id] = secret }
                return true
            },
            delete: { id in
                secrets.withLock { $0[id] = nil }
                return true
            })
    }
}

/// Key accounts' secrets, as the data services use them: read once and kept, and replaced or forgotten as the account
/// store changes them. Only the account store writes, and only data services read: neither views nor the
/// configuration ever see one. Changes to one account's secret happen one at a time, in the order asked.
final class AccountKeyring {
    private let secrets: AccountSecrets
    /// Each account's secret, read once; `nil` inside for an account without one.
    private var reads: [AccountID: Task<String?, Never>] = [:]
    private var writes: [AccountID: Task<Bool, Never>] = [:]
    private var observers: [(AccountID) -> Void] = []
    /// Secrets of versions before accounts moving to their accounts: reads wait for it.
    private var migration: Task<Void, Never>?

    init(secrets: AccountSecrets) {
        self.secrets = secrets
    }

    /// The secret of the key account `id`; `nil` when there's none, or it can't be read now.
    func secret(for id: AccountID) async -> String? {
        let read = reads[id] ?? readTask(id)
        reads[id] = read
        let secret = await read.value
        // Replaced or removed during this read: the newer answer stands.
        guard reads[id] == read else { return await self.secret(for: id) }
        return secret
    }

    private func readTask(_ id: AccountID) -> Task<String?, Never> {
        let secrets = secrets
        let pending = writes[id]
        let migration = migration
        return Task {
            await migration?.value
            _ = await pending?.value
            if case .found(let secret) = await secrets.lookUp(id) { return secret }
            return nil
        }
    }

    /// Reads wait for `migration`, which moves secrets into accounts' items.
    func waitFor(_ migration: Task<Void, Never>) {
        self.migration = migration
        reads = [:]
    }

    /// Calls `observer` with an account's ID whenever its secret is replaced or removed: what was fetched with the
    /// old one is no longer the account's.
    func observeChanges(_ observer: @escaping (AccountID) -> Void) {
        observers.append(observer)
    }

    /// Saves `secret` for `account`, replacing any; returns whether it was saved. Used from then on.
    func save(_ secret: String, for account: Account) async -> Bool {
        let secrets = secrets
        let write = queue(account.id) { await secrets.save(secret, account) }
        guard await write.value else {
            Log.accounts.error("Couldn't save a secret in the keychain")
            return false
        }
        reads[account.id] = Task { secret }
        for observer in observers { observer(account.id) }
        return true
    }

    /// Stops using the secret of `id` at once, and deletes it from the keychain; returns whether it's gone from there.
    @discardableResult
    func delete(_ id: AccountID) async -> Bool {
        reads[id] = Task { nil }
        for observer in observers { observer(id) }
        let secrets = secrets
        return await queue(id) { await secrets.delete(id) }.value
    }

    /// Runs `write` once the change before it to the same account is done.
    private func queue(_ id: AccountID, _ write: @escaping @Sendable () async -> Bool) -> Task<Bool, Never> {
        let previous = writes[id]
        let task = Task {
            _ = await previous?.value
            return await write()
        }
        writes[id] = task
        return task
    }
}

/// What a data service may do with accounts: read a key account's secret, hear when one changes, and say how an
/// account is doing. The composition root makes one from the keyring and the account store, for data services only.
struct AccountAccess {
    /// The secret of a key account; `nil` when there's none.
    var secret: (AccountID) async -> String?
    /// Registers a handler, called with an account's ID whenever its secret is replaced or removed.
    var observeChanges: (@escaping (AccountID) -> Void) -> Void
    /// Says how an account is doing, from a fetch.
    var report: (AccountStatus?, AccountID) -> Void
    /// Says whether an app sign-in's app was found, and whether it's signed in.
    var reportAppSignIn: (_ id: AccountID, _ isFound: Bool, _ isSignedIn: Bool) -> Void

    init(
        secret: @escaping (AccountID) async -> String?,
        observeChanges: @escaping (@escaping (AccountID) -> Void) -> Void = { _ in },
        report: @escaping (AccountStatus?, AccountID) -> Void = { _, _ in },
        reportAppSignIn: @escaping (AccountID, Bool, Bool) -> Void = { _, _, _ in }
    ) {
        self.secret = secret
        self.observeChanges = observeChanges
        self.report = report
        self.reportAppSignIn = reportAppSignIn
    }

    init(keyring: AccountKeyring, accounts: AccountStore) {
        self.init(
            secret: { await keyring.secret(for: $0) }, observeChanges: { keyring.observeChanges($0) },
            report: { [weak accounts] status, id in accounts?.report(status, for: id) },
            reportAppSignIn: { [weak accounts] id, isFound, isSignedIn in
                accounts?.appSignIn(id, isFound: isFound, isSignedIn: isSignedIn)
            })
    }
}
