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
        #expect(try await keyring.secret(for: account.id) == "sk-or-work")
        #expect(accounts.resolve(nil, at: .openRouter) == .account(account.id))
        // Nothing secret goes into the configuration.
        #expect(!String(decoding: try configuration.configuration.json(), as: UTF8.self).contains("sk-or-work"))
    }

    @Test func `an account whose key the keychain won't save isn't added`() async throws {
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
        #expect(try await keyring.secret(for: account.id) == "new")
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
        memory.read = { id in secrets.withLock { $0[id] } }
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
        #expect(try await keyring.secret(for: personal.id) == nil)
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
        #expect(try await keyring.secret(for: work.id) == nil)
    }

    @Test func `app profiles are saved with their folder, once each, and never touch the keychain`() async throws {
        var secrets = AccountSecrets.memory()
        secrets.save = { _, _ in
            Issue.record("An app profile saved a secret")
            return false
        }
        secrets.delete = { _ in
            Issue.record("An app profile deleted a secret")
            return false
        }
        let (accounts, _, configuration) = store(secrets)
        let work = accounts.addAppProfile(at: .claudeCode, name: " Work ", folder: "/tmp/claude-work")
        #expect(work.name == "Work" && work.kind == .appProfile && work.folder == "/tmp/claude-work")
        #expect(accounts.addAppProfile(at: .claudeCode, name: "Again", folder: "/tmp/claude-work") == work)
        #expect(accounts.appProfile(at: .claudeCode, inFolder: "/tmp/claude-work") == work)
        #expect(accounts.claudeCodeProfile(work.id) == ClaudeCodeProfile(configDirectory: "/tmp/claude-work"))
        // The default comes first.
        #expect(accounts.accounts(of: .claudeCode).map(\.name) == ["Claude Code", "Work"])
        accounts.makeDefault(work.id)
        #expect(accounts.accounts(of: .claudeCode).map(\.name) == ["Work", "Claude Code"])
        accounts.makeDefault(.claudeCodeApp)
        // Claude Code's own sign-in stays the default.
        #expect(accounts.resolve(nil, at: .claudeCode) == .account(.claudeCodeApp))
        #expect(await !accounts.replaceSecret(of: work.id, with: "nope"))

        accounts.report(.connected, for: work.id)
        accounts.identify("work@example.com · Max", for: work.id)
        #expect(accounts.identity(of: work.id) == "work@example.com · Max")
        accounts.remove(work.id)
        #expect(accounts.status(of: work.id) == nil && accounts.identity(of: work.id) == nil)
        #expect(configuration.configuration.accounts.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func `a key is read from the keychain once`() async throws {
        let lookUps = Mutex(0)
        var secrets = AccountSecrets.memory([AccountID(rawValue: "A"): "secret"])
        let read = secrets.read
        secrets.read = { id throws(KeychainUnavailable) in
            lookUps.withLock { $0 += 1 }
            return try await read(id)
        }
        let keyring = AccountKeyring(secrets: secrets)
        async let first = try keyring.secret(for: AccountID(rawValue: "A"))
        async let second = try keyring.secret(for: AccountID(rawValue: "A"))
        #expect(try await [first, second] == ["secret", "secret"])
        #expect(try await keyring.secret(for: AccountID(rawValue: "B")) == nil)
        #expect(lookUps.withLock { $0 } == 2)
    }

    @Test func `widgets say why they show no account's data, and nothing otherwise`() async throws {
        let (accounts, _, _) = store()
        #expect(AccountNotice(nil, at: .openRouter, in: accounts) == .addAccount)
        #expect(AccountNotice(.newKey(), at: .openRouter, in: accounts) == .chooseAccount(isMissing: true))
        let work = try #require(await accounts.add(at: .openRouter, name: "Work", secret: "key"))
        #expect(AccountNotice(nil, at: .openRouter, in: accounts) == nil)
        accounts.report(.failed("Can't reach OpenRouter"), for: work.id)
        #expect(AccountNotice(work.id, at: .openRouter, in: accounts) == nil)
        accounts.report(.expired, for: work.id)
        #expect(AccountNotice(work.id, at: .openRouter, in: accounts) == .signIn(work))
        _ = try #require(await accounts.add(at: .openRouter, name: "Personal", secret: "key 2"))
        accounts.makeDefault(work.id)
        accounts.remove(work.id)
        _ = try #require(await accounts.add(at: .openRouter, name: "Other", secret: "key 3"))
        #expect(AccountNotice(nil, at: .openRouter, in: accounts) == nil)
    }

    @Test func `asking for a provider's accounts opens Settings there`() {
        let navigator = SettingsNavigator()
        var shown = 0
        navigator.showSettings = { shown += 1 }
        navigator.showAccounts(.railway, adding: true)
        #expect(navigator.request == .accounts(provider: .railway, adding: true) && shown == 1)
        // Nothing to add at a provider whose app owns its sign-in.
        navigator.showAccounts(.codex, adding: true)
        #expect(navigator.request == .accounts(provider: .codex, adding: false))
    }

    @Test func `asking for the shortcuts opens Settings at their pane`() {
        let navigator = SettingsNavigator()
        var shown = 0
        navigator.showSettings = { shown += 1 }
        navigator.showShortcuts()
        #expect(navigator.request == .shortcuts && navigator.request?.pane == .shortcuts && shown == 1)
        #expect(navigator.request?.hasMoreThanPane == false)
    }

    @Test func `a read the keychain can't answer isn't taken for a missing key, and is asked again`() async throws {
        let fails = Mutex(true)
        var secrets = AccountSecrets.memory([AccountID(rawValue: "A"): "secret"])
        let read = secrets.read
        secrets.read = { id throws(KeychainUnavailable) in
            if fails.withLock({ $0 }) { throw KeychainUnavailable() }
            return try await read(id)
        }
        let keyring = AccountKeyring(secrets: secrets)
        await #expect(throws: KeychainUnavailable.self) { try await keyring.secret(for: AccountID(rawValue: "A")) }
        fails.withLock { $0 = false }
        #expect(try await keyring.secret(for: AccountID(rawValue: "A")) == "secret")
    }

    @Test func `the newest change to a key stands, however the keychain's answers interleave`() async throws {
        let gate = Answers<Bool>()
        var secrets = AccountSecrets.memory()
        let save = secrets.save
        secrets.save = { secret, account in
            // The first save waits for the test; later ones go straight through.
            if secret == "first" { _ = await gate.next() }
            return await save(secret, account)
        }
        let keyring = AccountKeyring(secrets: secrets)
        let account = Account.key(.openRouter, name: "Work")
        let first = Task { await keyring.save("first", for: account) }
        #expect(await eventually { gate.pendingCount == 1 })
        let second = Task { await keyring.save("second", for: account) }
        await gate.answer(true)
        _ = await (first.value, second.value)
        #expect(try await keyring.secret(for: account.id) == "second")

        // Removed while a save is still on its way: it stays removed.
        let third = Task { await keyring.save("first", for: account) }
        #expect(await eventually { gate.pendingCount == 1 })
        let removal = Task { await keyring.delete(account.id) }
        await gate.answer(true)
        _ = await (third.value, removal.value)
        #expect(try await keyring.secret(for: account.id) == nil)
    }

    @Test func `Railway problems only the person can fix ask them to`() {
        #expect(RailwayFetchProblem.notAuthorized.accountStatus == .needsSignIn)
        #expect(RailwayFetchProblem.noToken.accountStatus == .needsSignIn)
        #expect(RailwayFetchProblem.rejected(status: 401).accountStatus == .expired)
        #expect(RailwayFetchProblem.keychain.accountStatus.needsSignIn == false)
        #expect(RailwayFetchProblem.unreachable.accountStatus.needsSignIn == false)
    }
}
