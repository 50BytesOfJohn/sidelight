import Foundation
import Testing

@testable import SidelightCore

struct AccountModelTests {
    private let work = Account(
        id: AccountID(rawValue: "6F1C0000-0000-4000-8000-000000000001"), provider: .openRouter, name: "Work",
        kind: .key)
    private let personal = Account(
        id: AccountID(rawValue: "6F1C0000-0000-4000-8000-000000000002"), provider: .openRouter, name: "Personal",
        kind: .key)

    @Test func `accounts and defaults round-trip in the recommended shape`() throws {
        var configuration = AppConfiguration()
        configuration.accounts = [work, personal]
        configuration.defaultAccounts = [.openRouter: personal.id]
        let data = try configuration.json()
        #expect(try AppConfiguration(json: data) == configuration)

        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let accounts = try #require(json["accounts"] as? [[String: String]])
        #expect(
            accounts.first == ["id": work.id.rawValue, "provider": "openRouter", "name": "Work", "kind": "key"])
        #expect(json["defaultAccounts"] as? [String: String] == ["openRouter": personal.id.rawValue])
    }

    @Test func `a configuration without accounts has none`() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: AppConfiguration().json()) as? [String: Any])
        json["accounts"] = nil
        json["defaultAccounts"] = nil
        let configuration = try AppConfiguration(json: JSONSerialization.data(withJSONObject: json))
        #expect(configuration.accounts.isEmpty && configuration.defaultAccounts.isEmpty)
    }

    @Test func `accounts a newer version writes are left out, not the whole file`() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: AppConfiguration().json()) as? [String: Any])
        json["accounts"] = [
            ["id": "A", "provider": "vercel", "name": "Team", "kind": "key"],
            ["id": "B", "provider": "openRouter", "name": "Work", "kind": "oauth"],
            ["id": "C", "provider": "openRouter", "name": "Work", "kind": "key"],
            ["id": "C", "provider": "openRouter", "name": "Duplicate", "kind": "key"],
            ["id": "railway.cli", "provider": "railway", "name": "CLI", "kind": "appSignIn"],
        ]
        json["defaultAccounts"] = ["vercel": "A", "openRouter": "C"]
        let configuration = try AppConfiguration(json: JSONSerialization.data(withJSONObject: json))
        #expect(configuration.accounts.map(\.id.rawValue) == ["C"])
        #expect(configuration.accounts.first?.name == "Work")
        #expect(configuration.defaultAccounts == [.openRouter: AccountID(rawValue: "C")])
    }

    @Test func `derived IDs are the same every time, and differ by name`() {
        let first = AccountID.derived(from: "openRouter.shared")
        #expect(first == AccountID.derived(from: "openRouter.shared"))
        #expect(first != AccountID.derived(from: "railway.token"))
        let uuid = UUID(uuidString: first.rawValue)
        #expect(uuid != nil)
        // A name-based (version 5) UUID.
        #expect(first.rawValue.split(separator: "-")[2].first == "5")
    }

    @Test func `app sign-ins have fixed IDs and are found without being saved`() {
        let configuration = AppConfiguration()
        #expect(configuration.account(.railwayCLI)?.kind == .appSignIn)
        #expect(configuration.account(.claudeCodeApp)?.provider == .claudeCode)
        #expect(AccountProvider.openRouter.appSignIn == nil)
        #expect(configuration.account(AccountID(rawValue: "missing")) == nil)
    }

    @Test func `suggested names count up past the ones taken`() {
        var configuration = AppConfiguration()
        #expect(configuration.suggestedAccountName(for: .openRouter) == "OpenRouter")
        configuration.accounts = [Account.key(.openRouter, name: "OpenRouter")]
        #expect(configuration.suggestedAccountName(for: .openRouter) == "OpenRouter 2")
        configuration.accounts.append(Account.key(.openRouter, name: "OpenRouter 2"))
        #expect(configuration.suggestedAccountName(for: .openRouter) == "OpenRouter 3")
        #expect(configuration.suggestedAccountName(for: .railway) == "Railway")
    }
}

struct AccountResolutionTests {
    private let work = Account.key(.openRouter, name: "Work")
    private let personal = Account.key(.openRouter, name: "Personal")
    private let token = Account.key(.railway, name: "Railway")

    @Test func `a reference to an account that exists uses it`() {
        var configuration = AppConfiguration()
        configuration.accounts = [work, personal]
        configuration.defaultAccounts = [.openRouter: work.id]
        #expect(configuration.resolveAccount(personal.id, at: .openRouter) == .account(personal.id))
    }

    @Test func `a reference to a missing account never falls back to another`() {
        var configuration = AppConfiguration()
        configuration.accounts = [work]
        configuration.defaultAccounts = [.openRouter: work.id]
        let missing = AccountID.newKey()
        #expect(configuration.resolveAccount(missing, at: .openRouter) == .notFound(missing))
        // Another provider's account doesn't count either.
        configuration.accounts.append(token)
        #expect(configuration.resolveAccount(token.id, at: .openRouter) == .notFound(token.id))
    }

    @Test func `no reference uses the default, then the only account, then asks`() {
        var configuration = AppConfiguration()
        #expect(configuration.resolveAccount(nil, at: .openRouter) == .noAccount)
        configuration.accounts = [work]
        #expect(configuration.resolveAccount(nil, at: .openRouter) == .account(work.id))
        configuration.accounts.append(personal)
        #expect(configuration.resolveAccount(nil, at: .openRouter) == .chooseAccount)
        configuration.defaultAccounts = [.openRouter: personal.id]
        #expect(configuration.resolveAccount(nil, at: .openRouter) == .account(personal.id))
        // A default that's gone doesn't count.
        configuration.accounts = [work]
        #expect(configuration.resolveAccount(nil, at: .openRouter) == .account(work.id))
    }

    @Test func `Railway without a default uses the CLI while it's signed in, otherwise the token`() {
        var configuration = AppConfiguration()
        #expect(configuration.resolveAccount(nil, at: .railway) == .noAccount)
        #expect(configuration.resolveAccount(nil, at: .railway, signedIn: [.railwayCLI]) == .account(.railwayCLI))
        configuration.accounts = [token]
        #expect(configuration.resolveAccount(nil, at: .railway) == .account(token.id))
        #expect(configuration.resolveAccount(nil, at: .railway, signedIn: [.railwayCLI]) == .account(.railwayCLI))
        configuration.defaultAccounts = [.railway: token.id]
        #expect(configuration.resolveAccount(nil, at: .railway, signedIn: [.railwayCLI]) == .account(token.id))
        // The CLI can be named whether or not it's signed in: it says so itself.
        #expect(configuration.resolveAccount(.railwayCLI, at: .railway) == .account(.railwayCLI))
    }

    @Test func `providers with only an app sign-in use it`() {
        #expect(AppConfiguration().resolveAccount(nil, at: .claudeCode) == .account(.claudeCodeApp))
        #expect(AppConfiguration().resolveAccount(nil, at: .cursor) == .account(.cursorApp))
    }
}

struct AppSignInStatusTests {
    @Test func `Claude Code's status comes from the last fetch, or its plan without one`() {
        #expect(AccountStatus.claudeCode(fetched: nil, problem: nil, plan: nil) == nil)
        #expect(AccountStatus.claudeCode(fetched: nil, problem: nil, plan: "Max") == .connected)
        #expect(AccountStatus.claudeCode(fetched: nil, problem: .notSignedIn, plan: "Max") == .needsSignIn)
        #expect(AccountStatus.claudeCode(fetched: nil, problem: .signInExpired, plan: nil) == .expired)
        #expect(AccountStatus.claudeCode(fetched: nil, problem: .rejected(status: 401), plan: nil) == .expired)
        let unreachable = AccountStatus.claudeCode(fetched: nil, problem: .unreachable, plan: nil)
        #expect(unreachable == .failed(ClaudeCodeFetchProblem.unreachable.message))
        #expect(unreachable?.needsSignIn == false)
    }

    @Test func `Codex is signed in once its app-server says who as`() {
        #expect(AccountStatus.codex(CodexState()) == nil)
        #expect(AccountStatus.codex(CodexState(source: .appServer)) == .needsSignIn)
        #expect(AccountStatus.codex(CodexState(source: .appServer, problem: "Timed out")) == .failed("Timed out"))
    }

    @Test func `Cursor's status comes from the last fetch`() {
        #expect(AccountStatus.cursor(fetched: nil, problem: nil) == nil)
        #expect(AccountStatus.cursor(fetched: nil, problem: .notSignedIn) == .needsSignIn)
        #expect(AccountStatus.cursor(fetched: nil, problem: .rejected(status: 403)) == .expired)
        #expect(AccountStatus.cursor(fetched: nil, problem: .rejected(status: 500))?.needsSignIn == false)
    }
}
