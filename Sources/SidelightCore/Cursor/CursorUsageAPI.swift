import Foundation

/// The endpoint behind the Spending page of Cursor's web dashboard. Cursor has no public usage API for individual
/// plans (its Admin API is for team admins, with a team API key), so this is undocumented: if it changes, fetching
/// fails with ``CursorFetchProblem/unreadable`` or a rejection, and the widget says so.
public enum CursorUsageAPI {
    public static let url = URL(string: "https://cursor.com/api/usage-summary")!

    /// Signed in the way the dashboard is: with the session cookie, never stored in a cookie jar.
    public static func request(signIn: CursorSignIn, userAgent: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        request.setValue(signIn.sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Reads a response to ``request(signIn:userAgent:)``.
    public static func result(status: Int, body: Data, receivedAt: Date) -> Result<CursorUsage, CursorFetchProblem> {
        guard status == 200 else { return .failure(.rejected(status: status)) }
        guard let usage = CursorUsage(usageSummary: body, fetchedAt: receivedAt) else { return .failure(.unreadable) }
        return .success(usage)
    }
}

/// Why fetching usage from Cursor failed.
public enum CursorFetchProblem: Error, Equatable, Sendable {
    /// Neither the Cursor app nor the Cursor CLI is signed in on this Mac.
    case notSignedIn
    /// The only sign-ins found have expired. Cursor renews them itself the next time it's used.
    case signInExpired
    /// Cursor turned the request down with this HTTP status.
    case rejected(status: Int)
    case unreachable
    /// A response without usage Sidelight can read: the endpoint may have changed.
    case unreadable

    /// Rejections a different sign-in might not get.
    public var isSignInRejection: Bool {
        if case .rejected(let status) = self { return status == 401 || status == 403 }
        return false
    }
}

extension CursorFetchProblem {
    public var title: String {
        switch self {
        case .notSignedIn: "Not signed in to Cursor"
        case .signInExpired: "Cursor's sign-in has expired"
        case .rejected(let status) where status == 401 || status == 403: "Cursor didn't accept the sign-in"
        case .rejected(status: 429): "Cursor asked to slow down"
        case .rejected(let status): "Cursor answered HTTP \(status)"
        case .unreachable: "Can't reach cursor.com"
        case .unreadable: "No usage Sidelight can read"
        }
    }

    public var advice: String {
        switch self {
        case .notSignedIn: "Sign in to the Cursor app, or run cursor-agent login."
        case .signInExpired: "Open Cursor or run cursor-agent and it renews itself."
        case .rejected(let status) where status == 401 || status == 403:
            "Open Cursor to renew it, or sign out and in again."
        case .rejected(status: 429): "Trying less often."
        case .rejected, .unreachable: "Trying again later."
        case .unreadable: "Cursor's dashboard may have changed."
        }
    }

    /// Fixed by the user rather than by waiting.
    public var needsSignIn: Bool { self == .notSignedIn || self == .signInExpired || isSignInRejection }
}

/// A Cursor sign-in, as the Cursor app or CLI keeps it: a WorkOS access token, a JWT whose subject names the
/// user. Only read, never refreshed or written: refreshing would replace the sign-in Cursor holds. Its description
/// leaves the token out, so it can't end up in a log.
public struct CursorSignIn: Sendable, CustomStringConvertible {
    public enum Source: String, Sendable {
        /// The Cursor editor's state database.
        case app
        /// The Cursor CLI's keychain item.
        case cli
    }

    /// Where the Cursor app keeps its sign-in: the access token under ``appTokenKey`` in this SQLite database.
    public static let appStateDatabase = URL.homeDirectory.appending(
        path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb", directoryHint: .notDirectory)
    public static let appTokenKey = "cursorAuth/accessToken"
    /// The keychain item `cursor-agent login` saves its access token in.
    public static let cliKeychainService = "cursor-access-token"
    public static let cliKeychainAccount = "cursor-user"

    public var accessToken: String
    /// The WorkOS user ID (`user_…`), from the token's subject.
    public var userID: String
    public var expiresAt: Date?
    public var source: Source

    /// Reads the user and expiry from `token`'s claims, without verifying it: Cursor does that. `nil` when it
    /// isn't a JWT with a subject.
    public init?(accessToken token: String, source: Source) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = Self.base64URLDecoded(parts[1]),
            let claims = try? JSONDecoder().decode(Claims.self, from: payload),
            let subject = claims.sub,
            // `auth0|user_01…` → `user_01…`
            let userID = subject.split(separator: "|", omittingEmptySubsequences: false).last.map(String.init),
            !userID.isEmpty
        else { return nil }
        accessToken = token
        self.userID = userID
        expiresAt = claims.exp.map(Date.init(timeIntervalSince1970:))
        self.source = source
    }

    public func isExpired(at now: Date) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }

    /// The dashboard's session cookie: user ID and token joined by `::`, URL-encoded as the browser stores it.
    public var sessionCookie: String { "WorkosCursorSessionToken=\(userID)%3A%3A\(accessToken)" }

    public var description: String {
        "CursorSignIn(source: \(source.rawValue), expiresAt: \(String(describing: expiresAt)))"
    }

    private struct Claims: Decodable {
        var sub: String?
        var exp: Double?
    }

    private static func base64URLDecoded(_ part: Substring) -> Data? {
        var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
