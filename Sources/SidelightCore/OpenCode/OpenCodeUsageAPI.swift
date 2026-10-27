import Foundation
import SQLite3

/// The two OpenCode Console endpoints OpenCode itself reads its usage limits from (OpenCode 2's
/// `experimental.usage.limits` route): OpenCode Go's allowance at `opencode.ai/zen/go/v1/usage`, and the
/// workspace's budgets at `opencode.ai/console/api/policies/current-budgets`. Neither is documented, so if they
/// change, fetching fails with ``OpenCodeFetchProblem/unreadable`` or a rejection, and the widget says so.
public enum OpenCodeUsageAPI {
    /// Where the Console is when the sign-in doesn't say.
    public static let defaultConsole = URL(string: "https://opencode.ai/console")!

    public static func goUsageRequest(_ credential: OpenCodeCredential, userAgent: String) -> URLRequest {
        let origin = credential.console.scheme.flatMap { scheme in
            credential.console.host().map { "\(scheme)://\($0)" }
        }
        var request = request(
            URL(string: "\(origin ?? "https://opencode.ai")/zen/go/v1/usage")!, credential, userAgent: userAgent)
        if let workspace = credential.workspaceID {
            request.setValue(workspace, forHTTPHeaderField: "x-opencode-org-id")
        }
        return request
    }

    public static func budgetsRequest(_ credential: OpenCodeCredential, userAgent: String) -> URLRequest {
        var request = request(
            credential.console.appending(path: "api/policies/current-budgets"), credential, userAgent: userAgent)
        if let workspace = credential.workspaceID {
            request.setValue(workspace, forHTTPHeaderField: "x-org-id")
        }
        return request
    }

    private static func request(_ url: URL, _ credential: OpenCodeCredential, userAgent: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// One endpoint's answer: `nil` when there was none at all.
    public struct Answer: Sendable {
        public var status: Int
        public var body: Data

        public init(status: Int, body: Data) {
            self.status = status
            self.body = body
        }
    }

    /// Reads the answers to ``goUsageRequest(_:userAgent:)`` and ``budgetsRequest(_:userAgent:)``. Go answers 403
    /// for a workspace without a subscription, and the Console for one whose budgets this sign-in can't see, as
    /// OpenCode reads them. Go decides: budgets that can't be read leave Go's numbers standing.
    public static func result(
        go: Answer?, budgets: Answer?, credential: OpenCodeCredential, receivedAt: Date
    ) -> Result<OpenCodeUsage, OpenCodeFetchProblem> {
        var usage = OpenCodeUsage(workspaceName: credential.workspaceName, fetchedAt: receivedAt)
        guard let go else { return .failure(.unreachable) }
        switch go.status {
        case 200:
            guard let windows = OpenCodeUsage.goWindows(from: go.body) else { return .failure(.unreadable) }
            usage.go = windows
        case 403:
            break
        default:
            return .failure(.rejected(status: go.status))
        }
        if let budgets, budgets.status == 200 {
            usage.budgets = OpenCodeUsage.budgets(from: budgets.body) ?? []
        }
        return .success(usage)
    }
}

/// Why fetching usage from OpenCode failed.
public enum OpenCodeFetchProblem: Error, Equatable, Sendable {
    /// No OpenCode sign-in on this Mac, or no key saved for a key account.
    case notSignedIn
    /// OpenCode's sign-in has expired. OpenCode renews it the next time it's used.
    case signInExpired
    /// OpenCode's database couldn't be read.
    case unreadableSignIn
    /// The keychain wouldn't hand over the account's key just now.
    case keychainUnavailable
    /// OpenCode turned the request down with this HTTP status.
    case rejected(status: Int)
    case unreachable
    /// A response without usage Sidelight can read: the endpoint may have changed.
    case unreadable

    /// OpenCode didn't take the sign-in or key.
    public var isSignInRejection: Bool {
        if case .rejected(let status) = self { return status == 401 }
        return false
    }

    /// Fixed by the user rather than by waiting.
    public var needsSignIn: Bool { self == .notSignedIn || self == .signInExpired || isSignInRejection }

    public var title: String {
        switch self {
        case .notSignedIn: "Not signed in to OpenCode"
        case .signInExpired: "OpenCode's sign-in has expired"
        case .unreadableSignIn: "Can't read OpenCode's sign-in"
        case .keychainUnavailable: "The keychain is locked"
        case .rejected(status: 401): "OpenCode didn't accept the sign-in"
        case .rejected(status: 429): "OpenCode asked to slow down"
        case .rejected(let status): "OpenCode answered HTTP \(status)"
        case .unreachable: "Can't reach opencode.ai"
        case .unreadable: "No usage Sidelight can read"
        }
    }

    public var advice: String {
        switch self {
        case .notSignedIn: "Run opencode auth login, or add an OpenCode API key in Settings, under Accounts."
        case .signInExpired: "Run opencode and it renews itself."
        case .unreadableSignIn: "Trying again later."
        case .keychainUnavailable: "Trying again once it's unlocked."
        case .rejected(status: 401): "Sign in to OpenCode again, or replace the key."
        case .rejected(status: 429): "Trying less often."
        case .rejected, .unreachable: "Trying again later."
        case .unreadable: "OpenCode's Console may have changed."
        }
    }
}

/// What OpenCode is asked with: an OpenCode Console sign-in, as `opencode auth login` keeps it, or an API key. Only
/// read, never refreshed or written: refreshing would replace the sign-in OpenCode holds. Its description leaves the
/// token out, so it can't end up in a log.
public struct OpenCodeCredential: Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        /// OpenCode's Console sign-in: an OAuth access token, for one workspace.
        case signIn
        /// An API key, from the Console or OpenCode Go.
        case key
    }

    public var kind: Kind
    public var token: String
    /// The Console workspace (`wrk_…`) a sign-in is for; keys belong to one already.
    public var workspaceID: String?
    public var workspaceName: String?
    public var email: String?
    public var console: URL
    public var expiresAt: Date?

    public init(
        kind: Kind, token: String, workspaceID: String? = nil, workspaceName: String? = nil, email: String? = nil,
        console: URL = OpenCodeUsageAPI.defaultConsole, expiresAt: Date? = nil
    ) {
        self.kind = kind
        self.token = token
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.email = email
        self.console = console
        self.expiresAt = expiresAt
    }

    /// A key typed into Sidelight.
    public static func key(_ key: String) -> OpenCodeCredential {
        OpenCodeCredential(kind: .key, token: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func isExpired(at now: Date) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }

    /// `me@example.com · Personal`, where the sign-in says.
    public var identity: String? {
        let parts = [email, workspaceName].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public var description: String {
        "OpenCodeCredential(kind: \(kind.rawValue), workspace: \(workspaceID ?? "none"), "
            + "expiresAt: \(String(describing: expiresAt)))"
    }

    /// A stored credential's JSON, as OpenCode 2 keeps it in its `credential` table:
    /// `{"type": "oauth", "access", "refresh", "expires", "metadata": {"server", "orgID", "orgName", "email"}}`, or
    /// `{"type": "key", "key"}`. `nil` for any other kind, such as one an external command provides.
    public init?(stored data: Data) {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        self = stored.credential
    }

    private struct Stored: Decodable {
        var credential: OpenCodeCredential

        init(from decoder: any Decoder) throws {
            let root = try decoder.container(keyedBy: AnyCodingKey.self)
            let type = root.lenient(String.self, "type")
            let kind: Kind
            let token: String?
            switch type {
            case "oauth":
                kind = .signIn
                token = root.lenient(String.self, "access")
            case "key", "api":
                kind = .key
                token = root.lenient(String.self, "key")
            default:
                token = nil
                kind = .key
            }
            guard let token, !token.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: AnyCodingKey("type"), in: root, debugDescription: "No token Sidelight can use")
            }
            let metadata = try? root.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("metadata"))
            let server = metadata?.lenient(String.self, "server").flatMap(Self.console)
            credential = OpenCodeCredential(
                kind: kind, token: token, workspaceID: metadata?.lenient(String.self, "orgID"),
                workspaceName: metadata?.lenient(String.self, "orgName"),
                email: metadata?.lenient(String.self, "email"),
                console: server ?? OpenCodeUsageAPI.defaultConsole,
                expiresAt: root.lenientDouble("expires").map(Date.init(millisecondsSince1970:)))
        }

        /// The Console the sign-in names, moved from its old host as OpenCode does; only an HTTPS one is used, since
        /// the token goes to it.
        private static func console(_ server: String) -> URL? {
            let moved = server.replacing(
                /^https:\/\/console\.opencode\.ai(?=\/|$)/, with: "https://opencode.ai/console")
            guard let url = URL(string: moved), url.scheme == "https", url.host() != nil else { return nil }
            return url
        }
    }
}

// MARK: - OpenCode's own sign-in

/// What OpenCode's database says about its sign-in.
public enum OpenCodeSignIn: Sendable {
    case signedIn(OpenCodeCredential)
    /// OpenCode 2 is set up, without an OpenCode sign-in or key.
    case signedOut
    /// No OpenCode 2 database on this Mac.
    case notFound
    /// The database is there but couldn't be read: busy, or another format.
    case unreadable

    /// The integrations whose credentials are read, in order: OpenCode's Console (Zen and Go, signed in or with a
    /// key), then OpenCode Go connected with a key of its own.
    public static let integrations = ["opencode", "opencode-go"]

    /// Reads the credential OpenCode uses for the first of ``integrations`` that has one: the active one, or the most
    /// recently updated. Opened read-only, one query, so OpenCode's own use of the database is unaffected.
    public static func read(database: URL) -> OpenCodeSignIn {
        guard FileManager.default.fileExists(atPath: database.path(percentEncoded: false)) else { return .notFound }
        guard let connection = SQLiteReader.open(database) else { return .unreadable }
        defer { sqlite3_close(connection) }
        guard let columns = SQLiteReader.columns(of: "credential", in: connection) else { return .unreadable }
        guard columns.isSuperset(of: ["integration_id", "value", "active", "time_updated"]) else {
            return columns.isEmpty ? .signedOut : .unreadable
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = """
            SELECT integration_id, value FROM credential WHERE integration_id IN ('opencode', 'opencode-go')
            ORDER BY active DESC, time_updated DESC
            """
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK else { return .unreadable }
        var found: [String: OpenCodeCredential] = [:]
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let integration = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                found[integration] == nil, let bytes = sqlite3_column_blob(statement, 1),
                let credential = OpenCodeCredential(
                    stored: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1))))
            {
                found[integration] = credential
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { return .unreadable }
        return integrations.lazy.compactMap { found[$0] }.first.map(OpenCodeSignIn.signedIn) ?? .signedOut
    }
}
