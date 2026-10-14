import CryptoKit
import Foundation

/// Where Claude Code keeps one account's sign-in and state: its default folder, or another one `CLAUDE_CONFIG_DIR`
/// names. Claude Code keeps several accounts signed in at once that way, one per folder
/// (https://code.claude.com/docs/en/authentication#log-in-with-multiple-accounts), and Sidelight reads each the way
/// Claude Code saves it.
public struct ClaudeCodeProfile: Hashable, Sendable {
    /// `CLAUDE_CONFIG_DIR`, exactly as Claude Code is given it; `nil` for its default folder, `~/.claude`.
    public let configDirectory: String?

    /// Claude Code's default folder, used when `CLAUDE_CONFIG_DIR` isn't set.
    public static let standard = ClaudeCodeProfile(configDirectory: nil)

    /// `~/.claude`, in full.
    public static var defaultFolder: String {
        URL.homeDirectory.appending(path: ".claude", directoryHint: .notDirectory).path(percentEncoded: false)
    }

    /// An empty `configDirectory` is the default folder, as it is to Claude Code.
    public init(configDirectory: String?) {
        self.configDirectory = configDirectory.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `~/.claude.json` for the default folder, or `.claude.json` inside another.
    public var stateFileURL: URL {
        guard let configDirectory else {
            return URL.homeDirectory.appending(path: ".claude.json", directoryHint: .notDirectory)
        }
        return URL(filePath: configDirectory, directoryHint: .isDirectory)
            .appending(path: ".claude.json", directoryHint: .notDirectory)
    }

    /// Where Claude Code saves the sign-in when the keychain won't take it.
    public var credentialsFileURL: URL {
        URL(filePath: configDirectory ?? Self.defaultFolder, directoryHint: .isDirectory)
            .appending(path: ".credentials.json", directoryHint: .notDirectory)
    }

    /// The keychain item Claude Code saves the sign-in in: `Claude Code-credentials`, and for a folder
    /// `CLAUDE_CONFIG_DIR` names, a dash and ``folderHash`` after it.
    public var keychainService: String {
        ClaudeCodeCredentials.keychainService + (folderHash.map { "-\($0)" } ?? "")
    }

    /// What Sidelight's status line bridge saves this profile's status line input as, inside its own folder: the
    /// bridge tells profiles apart by ``folderHash``, as Claude Code's keychain does.
    public var statusLineFileName: String {
        folderHash.map { "status-line-\($0).json" } ?? "status-line.json"
    }

    /// How Claude Code is run to use this profile: `CLAUDE_CONFIG_DIR` set to the folder, or unset for the default.
    public var environment: [String: String?] {
        ["CLAUDE_CONFIG_DIR": configDirectory]
    }

    /// `CLAUDE_CONFIG_DIR=~/.sidelight/claude/work claude`, to use the profile in a terminal; just `claude` for the default.
    public var terminalCommand: String {
        guard let configDirectory else { return "claude" }
        return "CLAUDE_CONFIG_DIR=\(Self.shellWord(Self.abbreviatingHome(configDirectory))) claude"
    }

    /// The folder for people to read: `~/.sidelight/claude/work`.
    public var displayPath: String {
        Self.abbreviatingHome(configDirectory ?? Self.defaultFolder)
    }

    /// The first 8 hex digits of the folder's SHA-256 (of its NFC form), as Claude Code names its keychain item;
    /// `nil` for the default folder.
    var folderHash: String? {
        guard let configDirectory else { return nil }
        let digest = SHA256.hash(data: Data(configDirectory.precomposedStringWithCanonicalMapping.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func abbreviatingHome(_ path: String) -> String {
        let home = URL.homeDirectory.path(percentEncoded: false).trimmingSuffix("/")
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// `~/` stays outside quotes, so the shell still expands it; anything unusual after it is quoted.
    private static func shellWord(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+"))
        let (prefix, rest) = path.hasPrefix("~/") ? ("~/", String(path.dropFirst(2))) : ("", path)
        guard rest.unicodeScalars.contains(where: { !safe.contains($0) }) else { return path }
        return prefix + "'" + rest.replacing("'", with: #"'\''"#) + "'"
    }
}

// MARK: - New folders

extension ClaudeCodeProfile {
    /// `~/.sidelight/claude`, where Sidelight puts the folders of the Claude accounts it signs in. It's in the home
    /// folder rather than Application Support: each is a whole Claude Code folder, with the account's history and
    /// settings once it's used in a terminal, which removing Sidelight's own data mustn't take with it. And it's
    /// short to type there, with no spaces.
    public static func accountsFolder(in home: URL = .homeDirectory) -> URL {
        home.appending(path: ".sidelight/claude", directoryHint: .isDirectory)
    }

    /// A new folder for an account named `name`: `Work` → `~/.sidelight/claude/work`, easy to type in a terminal. A
    /// number follows when `isTaken` says the folder is in use already.
    public static func newFolder(
        named name: String, in home: URL = .homeDirectory, isTaken: (String) -> Bool
    ) -> String {
        var slug = name.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }
            .joined()
            .split(separator: "-").joined(separator: "-")
        // `Claude Personal` is `claude/personal`, not `claude/claude-personal`.
        if slug.hasPrefix("claude-") { slug.removeFirst("claude-".count) }
        if slug.isEmpty || slug == "claude" { slug = "account" }
        let base = accountsFolder(in: home).appending(path: slug, directoryHint: .isDirectory)
            .path(percentEncoded: false).trimmingSuffix("/")
        var folder = base
        var number = 2
        while isTaken(folder) {
            folder = "\(base)-\(number)"
            number += 1
        }
        return folder
    }
}

// MARK: - Folders signed in already

extension ClaudeCodeProfile {
    /// A folder Claude Code has signed in to, and who as.
    public struct SignedInFolder: Hashable, Sendable {
        public var profile: ClaudeCodeProfile
        public var email: String
    }

    /// Folders besides the default one that Claude Code has signed in to: the ones Sidelight made for accounts in
    /// ``accountsFolder(in:)``, then any like `~/.claude-work` in `home`, each by name. Reads only each folder's state
    /// file, never a sign-in: whether it's still signed in is Claude Code's to say.
    @concurrent
    public static func signedInFolders(in home: URL = .homeDirectory) async -> [SignedInFolder] {
        func folders(in parent: URL, where include: (String) -> Bool) -> [URL] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path(percentEncoded: false))) ?? []
            return names.filter(include).sorted().map { parent.appending(path: $0, directoryHint: .isDirectory) }
        }
        let candidates =
            folders(in: accountsFolder(in: home)) { !$0.hasPrefix(".") }
            + folders(in: home) { $0.hasPrefix(".claude") && $0 != ".claude" }
        return candidates.compactMap { url in
            let folder = url.path(percentEncoded: false)
            let profile = ClaudeCodeProfile(configDirectory: String(folder.trimmingSuffix("/")))
            guard let data = try? Data(contentsOf: profile.stateFileURL),
                let email = (try? ClaudeCodeAccountState(data: data))?.email
            else { return nil }
            return SignedInFolder(profile: profile, email: email)
        }
    }
}

// MARK: - Who's signed in

/// Who a Claude Code profile is signed in as, from `claude auth status --json`.
public struct ClaudeCodeIdentity: Equatable, Sendable {
    /// How the profile signs in, as Claude Code reports it: `claude.ai` for a Claude plan.
    public var authMethod: String
    public var email: String?
    public var organization: String?
    /// `pro`, `max`, `team`…
    public var subscription: String?

    public init(authMethod: String, email: String? = nil, organization: String? = nil, subscription: String? = nil) {
        self.authMethod = authMethod
        self.email = email
        self.organization = organization
        self.subscription = subscription
    }

    /// Signed in with a Claude plan, which is what has the limits Sidelight shows. An API key has none.
    public var hasPlan: Bool { authMethod == "claude.ai" }

    /// `me@example.com · Max`.
    public var summary: String? {
        Self.summary(email: email, plan: subscription.map { $0.prefix(1).uppercased() + $0.dropFirst() })
    }

    /// Who an account is signed in as, the same way whether Claude Code said so or its state file did:
    /// `me@example.com · Max`; `nil` when neither is known.
    public static func summary(email: String?, plan: String?) -> String? {
        let parts = [email, plan].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Reads `claude auth status --json`; `nil` when it says nobody is signed in, or can't be read.
    public init?(statusJSON data: Data) {
        guard case .signedIn(let identity) = ClaudeCodeAuthStatus(json: data) else { return nil }
        self = identity
    }

    fileprivate struct AuthStatus: Decodable {
        var loggedIn: Bool?
        var authMethod: String?
        var email: String?
        var orgName: String?
        var subscriptionType: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            loggedIn = container.lenient(Bool.self, "loggedIn")
            authMethod = container.lenient(String.self, "authMethod")
            email = container.lenient(String.self, "email")
            orgName = container.lenient(String.self, "orgName")
            subscriptionType = container.lenient(String.self, "subscriptionType")
        }
    }
}

/// What `claude auth status --json` says about a profile.
public enum ClaudeCodeAuthStatus: Equatable, Sendable {
    case signedIn(ClaudeCodeIdentity)
    case signedOut

    /// `nil` when the answer can't be read, which says nothing about whether anyone is signed in.
    public init?(json data: Data) {
        guard let status = try? JSONDecoder().decode(ClaudeCodeIdentity.AuthStatus.self, from: data),
            let loggedIn = status.loggedIn
        else { return nil }
        guard loggedIn, let authMethod = status.authMethod, authMethod != "none" else {
            self = .signedOut
            return
        }
        self = .signedIn(
            ClaudeCodeIdentity(
                authMethod: authMethod, email: status.email, organization: status.orgName,
                subscription: status.subscriptionType))
    }
}

// MARK: - Sign-in links

extension ClaudeCodeProfile {
    /// Whether `url` is a link Claude Code's sign-in may ask to open: `https` on Anthropic's own sites. Anything else
    /// is neither shown nor opened.
    public static func isSignInLink(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, let host = url.host()?.lowercased() else { return false }
        return ["claude.com", "claude.ai", "anthropic.com"].contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > suffix.count ? String(dropLast(suffix.count)) : self
    }
}
