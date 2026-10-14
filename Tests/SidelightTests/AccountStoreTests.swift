import Foundation
import Synchronization
import Testing

@testable import Sidelight
@testable import SidelightCore

struct AccountStoreTests {
    let directory = URL.temporaryDirectory.appending(path: "sidelight-accounts-\(UUID().uuidString)")

    private func store(
        _ secrets: AccountSecrets = .memory(), configure: (inout AppConfiguration) -> Void = { _ in }
    ) -> (AccountStore, AccountKeyring, ConfigurationStore) {
        let configuration = ConfigurationStore(fileURL: directory.appending(path: "config.json"))
        configure(&configuration.configuration)
        let keyring = AccountKeyring(secrets: secrets)
        return (AccountStore(configuration: configuration, keyring: keyring), keyring, configuration)
    }

    @Test func `adding an account saves its key first, and only then the account`() async throws {
        let (accounts, keyring, configuration) = store()
        let account = try #require(await accounts.add(at: .openRouter, name: "  Work ", secret: "sk-or-work"))
        #expect(account.name == "Work" && account.kind == .key)
        #expect(configuration.configuration.accounts == [account])
        #expect(await keyring.secret(for: account.id) == "sk-or-work")
        #expect(accounts.resolve(nil, at: .openRouter) == .account(account.id))
        // Nothing secret goes into the configuration.
        #expect(!String(decoding: try configuration.configuration.json(), as: UTF8.self).contains("sk-or-work"))
    }

    @Test func `an account whose key the keychain won't save isn't added`() async {
        var secrets = AccountSecrets.memory()
        secrets.save = { _, _ in false }
        let (accounts, _, configuration) = store(secrets)
        #expect(await accounts.add(at: .openRouter, name: "Work", secret: "sk-or-work") == nil)
        #expect(configuration.configuration.accounts.isEmpty)
    }

    @Test func `a second account keeps the first one the default`() async throws {
        let (accounts, _, configuration) = store()
        let first = try #require(await accounts.add(at: .openRouter, name: "", secret: "one"))
        #expect(first.name == "OpenRouter")
        #expect(configuration.configuration.defaultAccounts.isEmpty)
        #expect(accounts.suggestedName(for: .openRouter) == "OpenRouter 2")
        let second = try #require(await accounts.add(at: .openRouter, name: "OpenRouter 2", secret: "two"))
        #expect(configuration.configuration.defaultAccounts == [.openRouter: first.id])
        accounts.makeDefault(second.id)
        #expect(accounts.defaultAccount(for: .openRouter) == .account(second.id))
        accounts.rename(second.id, to: "Personal")
        accounts.rename(second.id, to: "   ")
        #expect(accounts.account(second.id)?.name == "Personal")
    }

    @Test func `Railway keeps using the CLI by default while it's signed in`() async throws {
        let (accounts, _, configuration) = store()
        accounts.appSignIn(.railwayCLI, isFound: true, isSignedIn: true)
        #expect(accounts.resolve(nil, at: .railway) == .account(.railwayCLI))
        _ = try #require(await accounts.add(at: .railway, name: "Acme", secret: "token"))
        _ = try #require(await accounts.add(at: .railway, name: "Other", secret: "token 2"))
        #expect(configuration.configuration.defaultAccounts.isEmpty)
        #expect(accounts.resolve(nil, at: .railway) == .account(.railwayCLI))
        #expect(accounts.choices(at: .railway).map(\.name) == ["Acme", "Other", "Railway CLI"])
        accounts.appSignIn(.railwayCLI, isFound: false, isSignedIn: false)
        #expect(accounts.choices(at: .railway).map(\.name) == ["Acme", "Other"])
    }

    @Test func `replacing a key uses the new one from then on`() async throws {
        let (accounts, keyring, _) = store()
        let account = try #require(await accounts.add(at: .openRouter, name: "Work", secret: "old"))
        let changed = Mutex<[AccountID]>([])
        keyring.observeChanges { id in changed.withLock { $0.append(id) } }
        accounts.report(.expired, for: account.id)
        #expect(await accounts.replaceSecret(of: account.id, with: "new"))
        #expect(await keyring.secret(for: account.id) == "new")
        #expect(changed.withLock { $0 } == [account.id])
        #expect(accounts.status(of: account.id) == nil)
        #expect(await !accounts.replaceSecret(of: .railwayCLI, with: "nope"))
    }

    @Test func `removing an account sends its widgets to the default and deletes its key`() async throws {
        let secrets = Mutex<[AccountID: String]>([:])
        var memory = AccountSecrets.memory()
        memory.save = { secret, account in
            secrets.withLock { $0[account.id] = secret }
            return true
        }
        memory.lookUp = { id in secrets.withLock { $0[id] }.map(KeychainLookup.found) ?? .missing }
        let deleted = Mutex<[AccountID]>([])
        memory.delete = { id in
            secrets.withLock { $0[id] = nil }
            deleted.withLock { $0.append(id) }
            return true
        }
        let (accounts, keyring, configuration) = store(memory)
        let work = try #require(await accounts.add(at: .openRouter, name: "Work", secret: "work"))
        let personal = try #require(await accounts.add(at: .openRouter, name: "Personal", secret: "personal"))
        var settings = OpenRouterSettings(preset: .credits)
        settings.setBalanceOptions(.init(account: personal.id), for: OpenRouterPreset.balanceID)
        configuration.configuration.sections[0].widgets.append(WidgetInstance(settings: .openRouter(settings)))
        #expect(accounts.uses(of: personal.id) == 1)

        accounts.remove(personal.id)
        #expect(configuration.configuration.accounts == [work])
        #expect(configuration.configuration.references(to: personal.id) == 0)
        #expect(accounts.uses(of: work.id) == 1)
        // Not used again, even before the keychain is done.
        #expect(await keyring.secret(for: personal.id) == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(deleted.withLock { $0 } == [personal.id])
        #expect(secrets.withLock { $0[personal.id] } == nil)
    }

    @Test func `a key the keychain can't delete still leaves with its account`() async throws {
        var secrets = AccountSecrets.memory()
        secrets.delete = { _ in false }
        let (accounts, keyring, configuration) = store(secrets)
        let work = try #require(await accounts.add(at: .openRouter, name: "Work", secret: "work"))
        accounts.remove(work.id)
        #expect(configuration.configuration.accounts.isEmpty)
        #expect(await keyring.secret(for: work.id) == nil)
    }

    @Test func `a key is read from the keychain once`() async {
        let lookUps = Mutex(0)
        var secrets = AccountSecrets.memory([AccountID(rawValue: "A"): "secret"])
        let lookUp = secrets.lookUp
        secrets.lookUp = { id in
            lookUps.withLock { $0 += 1 }
            return await lookUp(id)
        }
        let keyring = AccountKeyring(secrets: secrets)
        async let first = keyring.secret(for: AccountID(rawValue: "A"))
        async let second = keyring.secret(for: AccountID(rawValue: "A"))
        #expect(await [first, second] == ["secret", "secret"])
        #expect(await keyring.secret(for: AccountID(rawValue: "B")) == nil)
        #expect(lookUps.withLock { $0 } == 2)
    }

    @Test func `widgets say why they show no account's data, and nothing otherwise`() async throws {
        let (accounts, _, _) = store()
        let navigator = SettingsNavigator()
        func title(_ resolution: AccountResolution) -> String? {
            AccountMessage(
                resolution, provider: .openRouter, accounts: accounts, navigator: navigator, widget: UUID(),
                layout: .regular)?.message.title
        }
        #expect(title(.noAccount) == "Add an account to see OpenRouter data.")
        #expect(title(.notFound(.newKey())) == "Account not found.")
        let work = try #require(await accounts.add(at: .openRouter, name: "Work", secret: "key"))
        #expect(title(.account(work.id)) == nil)
        accounts.report(.failed("Can't reach OpenRouter"), for: work.id)
        #expect(title(.account(work.id)) == nil)
        accounts.report(.expired, for: work.id)
        #expect(title(.account(work.id)) == "Work needs you to sign in again.")
        accounts.isMovingLegacySecrets = true
        #expect(title(.noAccount) == "Loading accounts…")
    }

    @Test func `asking for a provider's accounts opens Settings there`() {
        let navigator = SettingsNavigator()
        var shown = 0
        navigator.showSettings = { shown += 1 }
        navigator.showAccounts(.railway, adding: true)
        #expect(navigator.request == .init(provider: .railway, adding: true) && shown == 1)
        // Nothing to add at a provider whose app owns its sign-in.
        navigator.showAccounts(.codex, adding: true)
        #expect(navigator.request == .init(provider: .codex, adding: false))
    }
}
