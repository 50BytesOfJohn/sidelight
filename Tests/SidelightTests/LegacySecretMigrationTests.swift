import Foundation
import Synchronization
import Testing

@testable import Sidelight
@testable import SidelightCore

/// Old secrets and notes kept in memory, standing in for the keychain items and `.removed` files of versions before
/// accounts.
private final class OldSecrets: Sendable {
    let items: Mutex<[LegacySecret.Source: String]>
    let removals: Mutex<Set<LegacySecret.Source>>
    let failsDelete = Mutex(false)

    init(_ items: [LegacySecret.Source: String] = [:], removed: Set<LegacySecret.Source> = []) {
        self.items = Mutex(items)
        removals = Mutex(removed)
    }

    var location: LegacySecretLocation {
        LegacySecretLocation(
            lookUp: { source in self.items.withLock { $0[source] }.map(KeychainLookup.found) ?? .missing },
            delete: { source in
                guard !self.failsDelete.withLock({ $0 }) else { return false }
                self.items.withLock { $0[source] = nil }
                return true
            },
            removal: { source in self.removals.withLock { $0.contains(source) } ? .noted : .none },
            forgetRemoval: { source in
                _ = self.removals.withLock { $0.remove(source) }
                return true
            })
    }
}

/// Accounts' secrets in memory, readable from the test.
private final class NewSecrets: Sendable {
    let items: Mutex<[AccountID: String]>
    let failsSave = Mutex(false)
    let corruptsSave = Mutex(false)

    init(_ items: [AccountID: String] = [:]) {
        self.items = Mutex(items)
    }

    subscript(id: AccountID) -> String? { items.withLock { $0[id] } }

    var secrets: AccountSecrets {
        AccountSecrets(
            lookUp: { id in self.items.withLock { $0[id] }.map(KeychainLookup.found) ?? .missing },
            save: { secret, account in
                guard !self.failsSave.withLock({ $0 }) else { return false }
                let saved = self.corruptsSave.withLock { $0 } ? secret + "?" : secret
                self.items.withLock { $0[account.id] = saved }
                return true
            },
            delete: { id in
                self.items.withLock { $0[id] = nil }
                return true
            })
    }
}

struct LegacySecretMigrationTests {
    let directory = URL.temporaryDirectory.appending(path: "sidelight-migration-\(UUID().uuidString)")
    private let widget = UUID(uuidString: "00000000-0000-4000-8000-000000000019")!
    private let block = UUID(uuidString: "00000000-0000-4000-8000-000000000503")!

    /// A configuration as loaded from before accounts: a Railway widget set to the token, and an OpenRouter widget
    /// whose block used its own key.
    private func configuration() -> ConfigurationStore {
        let store = ConfigurationStore(fileURL: directory.appending(path: "config.json"))
        var credits = OpenRouterSettings(preset: .credits)
        credits.blocks.add(.balance(block))
        credits.setBalanceOptions(
            .init(title: "Personal", account: .migratedOpenRouterKey(widget: widget, block: block)), for: block)
        store.configuration.sections[0].widgets += [
            WidgetInstance(settings: .railway(RailwaySettings(account: .migratedRailwayToken))),
            WidgetInstance(id: widget, settings: .openRouter(credits)),
        ]
        return store
    }

    private var own: AccountID { .migratedOpenRouterKey(widget: widget, block: block) }

    @Test func `every old secret moves to its account, which is then added`() async {
        let old = OldSecrets([
            .openRouterShared: "sk-or-shared", .openRouterBlock(widget: widget, block: block): "sk-or-own",
            .railwayToken: "railway-token",
        ])
        let new = NewSecrets()
        let store = configuration()
        let outcomes = await LegacySecretMigration(old: old.location, new: new.secrets).run(on: store)
        #expect(Set(outcomes.values) == [.moved])
        #expect(new[.migratedOpenRouterKey] == "sk-or-shared")
        #expect(new[own] == "sk-or-own")
        #expect(new[.migratedRailwayToken] == "railway-token")
        #expect(old.items.withLock { $0.isEmpty })
        let accounts = store.configuration.accounts
        #expect(accounts.map(\.name) == ["OpenRouter", "Railway", "Personal"])
        #expect(store.configuration.defaultAccounts == [.openRouter: .migratedOpenRouterKey])
        #expect(store.configuration.references(to: own) == 1)
        #expect(store.configuration.references(to: .migratedRailwayToken) == 1)

        // Again, as at the next launch: nothing changes.
        let before = store.configuration
        let again = await LegacySecretMigration(old: old.location, new: new.secrets).run(on: store)
        #expect(Set(again.values) == [.moved])
        #expect(store.configuration == before)
    }

    @Test func `without old secrets no account is added, and widgets go back to the default`() async {
        let store = configuration()
        let outcomes = await LegacySecretMigration(old: OldSecrets().location, new: NewSecrets().secrets)
            .run(on: store)
        #expect(Set(outcomes.values) == [.dropped])
        #expect(store.configuration.accounts.isEmpty)
        #expect(store.configuration.references(to: own) == 0)
        #expect(store.configuration.references(to: .migratedRailwayToken) == 0)
    }

    @Test func `a key someone removed isn't moved, and its item and note go`() async {
        let source = LegacySecret.Source.openRouterBlock(widget: widget, block: block)
        let old = OldSecrets([.openRouterShared: "shared", source: "removed"], removed: [source])
        let new = NewSecrets()
        let store = configuration()
        await LegacySecretMigration(old: old.location, new: new.secrets).run(on: store)
        #expect(new[own] == nil)
        #expect(old.items.withLock { $0.isEmpty })
        #expect(old.removals.withLock { $0.isEmpty })
        #expect(store.configuration.accounts.map(\.name) == ["OpenRouter"])
        #expect(store.configuration.references(to: own) == 0)
    }

    @Test func `an item already there is never overwritten`() async {
        let old = OldSecrets([.openRouterShared: "old"])
        let new = NewSecrets([.migratedOpenRouterKey: "newer"])
        let store = configuration()
        await LegacySecretMigration(old: old.location, new: new.secrets).run(on: store)
        #expect(new[.migratedOpenRouterKey] == "newer")
        // Different: kept, in case.
        #expect(old.items.withLock { $0[.openRouterShared] } == "old")
        #expect(store.configuration.accounts.map(\.id) == [.migratedOpenRouterKey])
    }

    @Test func `a copy that fails or reads back wrong keeps the old item for the next launch`() async {
        let old = OldSecrets([.railwayToken: "token"])
        let new = NewSecrets()
        let store = configuration()
        new.failsSave.withLock { $0 = true }
        var outcomes = await LegacySecretMigration(old: old.location, new: new.secrets).run(on: store)
        #expect(outcomes.first { $0.key.source == .railwayToken }?.value == .retry)
        new.failsSave.withLock { $0 = false }
        new.corruptsSave.withLock { $0 = true }
        outcomes = await LegacySecretMigration(old: old.location, new: new.secrets).run(on: store)
        #expect(outcomes.first { $0.key.source == .railwayToken }?.value == .retry)
        #expect(new[.migratedRailwayToken] == nil)
        #expect(old.items.withLock { $0[.railwayToken] } == "token")
        // Still named, and not added, until it moves.
        #expect(store.configuration.references(to: .migratedRailwayToken) == 1)
        #expect(store.configuration.accounts.isEmpty)

        new.corruptsSave.withLock { $0 = false }
        await LegacySecretMigration(old: old.location, new: new.secrets).run(on: store)
        #expect(new[.migratedRailwayToken] == "token")
        #expect(store.configuration.accounts.map(\.id) == [.migratedRailwayToken])
    }

    @Test func `a copy whose old item can't be deleted still counts, and is cleaned up later`() async {
        let old = OldSecrets([.openRouterShared: "shared"])
        old.failsDelete.withLock { $0 = true }
        let new = NewSecrets()
        let store = configuration()
        await LegacySecretMigration(old: old.location, new: new.secrets).run(on: store)
        #expect(store.configuration.accounts.map(\.id) == [.migratedOpenRouterKey])
        old.failsDelete.withLock { $0 = false }
        await LegacySecretMigration(old: old.location, new: new.secrets).run(on: store)
        #expect(old.items.withLock { $0.isEmpty })
    }

    @Test func `a debug build copies the secrets but leaves them for the installed release`() async {
        let old = OldSecrets([.openRouterShared: "shared"])
        let new = NewSecrets()
        let store = configuration()
        await LegacySecretMigration(old: old.location, new: new.secrets, keepsOldSecrets: true).run(on: store)
        #expect(new[.migratedOpenRouterKey] == "shared")
        #expect(old.items.withLock { $0[.openRouterShared] } == "shared")
    }

    @Test func `widgets wait for the move before they read a key`() async {
        let old = OldSecrets([.openRouterShared: "shared"])
        let new = NewSecrets()
        let store = configuration()
        let keyring = AccountKeyring(secrets: new.secrets)
        let accounts = AccountStore(configuration: store, keyring: keyring)
        accounts.moveLegacySecrets(LegacySecretMigration(old: old.location, new: new.secrets))
        #expect(accounts.isMovingLegacySecrets)
        #expect(await keyring.secret(for: .migratedOpenRouterKey) == "shared")
        #expect(accounts.resolve(nil, at: .openRouter) == .account(.migratedOpenRouterKey))
    }
}
