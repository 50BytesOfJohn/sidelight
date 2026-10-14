import Foundation
import Testing

@testable import SidelightCore

struct ClaudeCodeProfileTests {
    private let home = URL.homeDirectory.path(percentEncoded: false).trimmingCharacters(in: ["/"])

    @Test func `the default folder reads what Claude Code saves without CLAUDE_CONFIG_DIR`() {
        let profile = ClaudeCodeProfile.standard
        #expect(profile.keychainService == "Claude Code-credentials")
        #expect(profile.stateFileURL == URL.homeDirectory.appending(path: ".claude.json"))
        #expect(profile.credentialsFileURL.path(percentEncoded: false).hasSuffix("/.claude/.credentials.json"))
        #expect(profile.statusLineFileName == "status-line.json")
        #expect(profile.terminalCommand == "claude")
        #expect(profile.displayPath == "~/.claude")
        #expect(profile.environment == ["CLAUDE_CONFIG_DIR": String?.none])
        #expect(ClaudeCodeProfile(configDirectory: "") == .standard)
    }

    @Test func `another folder is named by its hash, as Claude Code names its keychain item`() {
        let profile = ClaudeCodeProfile(configDirectory: "/tmp/claude-work")
        // `printf '%s' /tmp/claude-work | shasum -a 256 | cut -c1-8`, as the status line bridge works it out.
        #expect(profile.keychainService == "Claude Code-credentials-bfc1769a")
        #expect(profile.statusLineFileName == "status-line-bfc1769a.json")
        #expect(profile.stateFileURL.path(percentEncoded: false) == "/tmp/claude-work/.claude.json")
        #expect(profile.credentialsFileURL.path(percentEncoded: false) == "/tmp/claude-work/.credentials.json")
        #expect(profile.environment == ["CLAUDE_CONFIG_DIR": "/tmp/claude-work"])
    }

    @Test func `the hash is of the folder's composed form`() {
        let decomposed = ClaudeCodeProfile(configDirectory: "/tmp/Claude\u{301}")
        let composed = ClaudeCodeProfile(configDirectory: "/tmp/Claud\u{E9}")
        #expect(decomposed.keychainService == "Claude Code-credentials-31f161e6")
        #expect(composed.keychainService == decomposed.keychainService)
    }

    @Test func `the terminal command keeps the home folder short, and quotes what the shell would split`() {
        let work = ClaudeCodeProfile(configDirectory: "/\(home)/.claude-work")
        #expect(work.terminalCommand == "CLAUDE_CONFIG_DIR=~/.claude-work claude")
        #expect(work.displayPath == "~/.claude-work")
        let spaced = ClaudeCodeProfile(configDirectory: "/\(home)/Claude Accounts/it's work")
        #expect(spaced.terminalCommand == #"CLAUDE_CONFIG_DIR=~/'Claude Accounts/it'\''s work' claude"#)
        #expect(
            ClaudeCodeProfile(configDirectory: "/opt/claude").terminalCommand == "CLAUDE_CONFIG_DIR=/opt/claude claude")
    }

    @Test func `new folders are named after the account, and never one in use`() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        func folder(_ name: String, taken: Set<String> = []) -> String {
            ClaudeCodeProfile.newFolder(named: name, in: home) { taken.contains($0) }
        }
        #expect(folder("Work") == "/Users/someone/.sidelight/claude/work")
        #expect(folder("  Side Project! ") == "/Users/someone/.sidelight/claude/side-project")
        #expect(folder("Claude Personal") == "/Users/someone/.sidelight/claude/personal")
        #expect(folder("Claude") == "/Users/someone/.sidelight/claude/account")
        #expect(folder("Żółw") == "/Users/someone/.sidelight/claude/w")
        #expect(folder("") == "/Users/someone/.sidelight/claude/account")
        #expect(
            folder("Work", taken: ["/Users/someone/.sidelight/claude/work", "/Users/someone/.sidelight/claude/work-2"])
                == "/Users/someone/.sidelight/claude/work-3")
    }

    @Test func `folders signed in already are found by their state file`() async throws {
        let home = URL.temporaryDirectory.appending(
            path: "claude-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        func folder(_ name: String, state: String?) throws {
            let url = home.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if let state { try Data(state.utf8).write(to: url.appending(path: ".claude.json")) }
        }
        try folder(".claude", state: #"{"oauthAccount":{"emailAddress":"default@example.com"}}"#)
        try folder(".claude-work", state: #"{"oauthAccount":{"emailAddress":"work@example.com"}}"#)
        try folder(".claude-new", state: #"{"numStartups":1}"#)
        try folder(".claude-empty", state: nil)
        try folder("claude-other", state: #"{"oauthAccount":{"emailAddress":"other@example.com"}}"#)
        try folder(".sidelight/claude/personal", state: #"{"oauthAccount":{"emailAddress":"me@example.com"}}"#)
        try folder(".sidelight/claude/unfinished", state: nil)

        let found = await ClaudeCodeProfile.signedInFolders(in: home)
        #expect(found.map(\.email) == ["me@example.com", "work@example.com"])
        #expect(found.first?.profile.configDirectory?.hasSuffix("/.sidelight/claude/personal") == true)
        #expect(found.last?.profile.configDirectory?.hasSuffix("/.claude-work") == true)
        #expect(found.allSatisfy { $0.profile.configDirectory?.hasSuffix("/") == false })
    }
}

struct ClaudeCodeIdentityTests {
    @Test func `reads who's signed in from claude auth status`() {
        let status = #"""
            {"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "email": "me@example.com",
             "orgId": "o1", "orgName": "Acme", "subscriptionType": "max", "configDirectory": "/tmp/x"}
            """#
        let identity = ClaudeCodeIdentity(statusJSON: Data(status.utf8))
        #expect(
            identity
                == ClaudeCodeIdentity(
                    authMethod: "claude.ai", email: "me@example.com", organization: "Acme", subscription: "max"))
        #expect(identity?.hasPlan == true)
        #expect(identity?.summary == "me@example.com · Max")
        #expect(ClaudeCodeIdentity.summary(email: nil, plan: "Pro") == "Pro")
        #expect(ClaudeCodeIdentity.summary(email: "", plan: nil) == nil)
    }

    @Test func `nobody signed in, or an API key, is told apart`() {
        #expect(ClaudeCodeIdentity(statusJSON: Data(#"{"loggedIn": false, "authMethod": "none"}"#.utf8)) == nil)
        #expect(ClaudeCodeIdentity(statusJSON: Data("Not logged in".utf8)) == nil)
        let key = ClaudeCodeIdentity(statusJSON: Data(#"{"loggedIn": true, "authMethod": "api_key"}"#.utf8))
        #expect(key?.hasPlan == false)
    }

    @Test func `the state file says which email is signed in`() throws {
        let state = #"{"oauthAccount":{"emailAddress":"me@example.com","organizationType":"claude_pro"}}"#
        #expect(
            try ClaudeCodeAccountState(data: Data(state.utf8))
                == ClaudeCodeAccountState(plan: "Pro", email: "me@example.com"))
    }
}

struct ClaudeAccountModelTests {
    private let work = Account.appProfile(.claudeCode, name: "Work", folder: "/tmp/claude-work")

    private func configuration(_ widgets: [WidgetInstance] = []) -> AppConfiguration {
        var configuration = AppConfiguration()
        configuration.accounts = [work]
        configuration.sections = [PanelSection(widgets: widgets)]
        return configuration
    }

    @Test func `app profiles are saved with their folder, and nothing else of the sign-in`() throws {
        let configuration = configuration()
        let data = try configuration.json()
        #expect(try AppConfiguration(json: data) == configuration)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let accounts = try #require(json["accounts"] as? [[String: String]])
        #expect(
            accounts == [
                [
                    "id": work.id.rawValue, "provider": "claudeCode", "name": "Work", "kind": "appProfile",
                    "folder": "/tmp/claude-work",
                ]
            ])
    }

    @Test func `app profiles without a folder, or where there are none, are left out`() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: AppConfiguration().json()) as? [String: Any])
        json["accounts"] = [
            ["id": "A", "provider": "claudeCode", "name": "No folder", "kind": "appProfile"],
            ["id": "B", "provider": "claudeCode", "name": "Empty", "kind": "appProfile", "folder": ""],
            ["id": "C", "provider": "openRouter", "name": "Keys only", "kind": "appProfile", "folder": "/tmp/x"],
            ["id": "D", "provider": "claudeCode", "name": "Work", "kind": "appProfile", "folder": "/tmp/w"],
        ]
        let configuration = try AppConfiguration(json: JSONSerialization.data(withJSONObject: json))
        #expect(configuration.accounts.map(\.id.rawValue) == ["D"])
    }

    @Test func `Claude widgets use Claude Code's own sign-in unless they name a profile`() {
        var configuration = configuration()
        #expect(configuration.resolveAccount(nil, at: .claudeCode) == .account(.claudeCodeApp))
        #expect(configuration.resolveAccount(work.id, at: .claudeCode) == .account(work.id))
        configuration.defaultAccounts = [.claudeCode: work.id]
        #expect(configuration.resolveAccount(nil, at: .claudeCode) == .account(work.id))
        configuration.removeAccount(work.id)
        #expect(configuration.defaultAccounts.isEmpty)
        #expect(configuration.resolveAccount(nil, at: .claudeCode) == .account(.claudeCodeApp))
        #expect(configuration.resolveAccount(work.id, at: .claudeCode) == .notFound(work.id))
    }

    @Test func `each Claude account has its folder`() {
        let configuration = configuration()
        #expect(configuration.claudeCodeProfile(.claudeCodeApp) == .standard)
        #expect(configuration.claudeCodeProfile(work.id) == ClaudeCodeProfile(configDirectory: "/tmp/claude-work"))
        #expect(configuration.claudeCodeProfile(.railwayCLI) == nil)
        #expect(configuration.suggestedAccountName(for: .claudeCode) == "Claude Code 2")
    }

    @Test func `each Claude account fetches once, as often as its most frequent widget asks`() {
        let configuration = configuration([
            WidgetInstance(settings: .claudeCode(ClaudeCodeSettings(refreshesFromAnthropic: true, refreshMinutes: 15))),
            WidgetInstance(
                settings: .aiUsage(AIUsageSettings(refreshesClaudeFromAnthropic: true, claudeRefreshMinutes: 5))),
            WidgetInstance(settings: .claudeCode(ClaudeCodeSettings(account: work.id))),
            WidgetInstance(
                settings: .aiUsage(
                    AIUsageSettings(
                        providers: [.codex], claudeAccount: work.id, refreshesClaudeFromAnthropic: true,
                        claudeRefreshMinutes: 2))),
            WidgetInstance(settings: .claudeCode(ClaudeCodeSettings(account: AccountID(rawValue: "gone")))),
        ])
        #expect(
            configuration.serviceDemand(at: [.left]).claudeCode == [
                .claudeCodeApp: ClaudeCodeNeeds(profile: .standard, refreshMinutes: 5),
                work.id: ClaudeCodeNeeds(profile: ClaudeCodeProfile(configDirectory: "/tmp/claude-work")),
            ])
    }

    @Test func `the Widgets window previews Claude on the default account`() {
        let demand = configuration().serviceDemand(at: [], previewsEveryWidget: true)
        #expect(demand.claudeCode == [.claudeCodeApp: ClaudeCodeNeeds(profile: .standard)])
        #expect(demand.limited(to: [.clock]).claudeCode.isEmpty)
        #expect(demand.limited(to: [.aiUsage]).claudeCode == demand.claudeCode)
    }

    @Test func `widgets naming a removed Claude account go back to the default`() {
        var configuration = configuration([
            WidgetInstance(settings: .claudeCode(ClaudeCodeSettings(account: work.id))),
            WidgetInstance(settings: .aiUsage(AIUsageSettings(claudeAccount: work.id))),
            WidgetInstance(settings: .aiUsage(AIUsageSettings(providers: [.codex], claudeAccount: work.id))),
        ])
        // The AI Usage widget showing only Codex doesn't use it.
        #expect(configuration.references(to: work.id) == 2 && configuration.uses(of: work.id) == 2)
        #expect(configuration.uses(of: .claudeCodeApp) == 0)
        configuration.removeAccount(work.id)
        #expect(configuration.references(to: work.id) == 0)
        #expect(configuration.uses(of: .claudeCodeApp) == 2)
        guard case .aiUsage(let codexOnly) = configuration.widgets.last?.settings else {
            Issue.record("Expected AI Usage settings")
            return
        }
        #expect(codexOnly.claudeAccount == nil)
    }

    @Test func `Claude settings saved before accounts still load, and keep the account they name`() throws {
        let old = try JSONDecoder().decode(ClaudeCodeSettings.self, from: Data(#"{"showsWeeklyLimit":false}"#.utf8))
        #expect(old.account == nil)
        let settings = ClaudeCodeSettings(account: work.id)
        #expect(try JSONDecoder().decode(ClaudeCodeSettings.self, from: JSONEncoder().encode(settings)) == settings)
        let usage = AIUsageSettings(claudeAccount: work.id)
        #expect(try JSONDecoder().decode(AIUsageSettings.self, from: JSONEncoder().encode(usage)) == usage)
        let odd = try JSONDecoder().decode(ClaudeCodeSettings.self, from: Data(#"{"account":42}"#.utf8))
        #expect(odd.account == nil)
    }
}
