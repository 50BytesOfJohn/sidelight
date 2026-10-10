import Foundation

/// The endpoint Claude Code's `/usage` reads the plan's limits from. It isn't a documented API: if it changes,
/// fetching fails and the widget falls back to what Claude Code saves locally.
public enum ClaudeCodeUsageAPI {
    public static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Requests signed in with a Claude account rather than an API key have to opt in to this beta.
    static let oauthBeta = "oauth-2025-04-20"

    public static func request(accessToken: String, userAgent: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(oauthBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Reads a response to ``request(accessToken:userAgent:)``.
    public static func result(
        status: Int, body: Data, receivedAt: Date
    ) -> Result<ClaudeCodeUsage, ClaudeCodeFetchProblem> {
        guard status == 200 else { return .failure(.rejected(status: status)) }
        guard let usage = ClaudeCodeUsage(usageResponse: body, fetchedAt: receivedAt) else {
            return .failure(.unreadable)
        }
        return .success(usage)
    }

    /// After a failure, every further one in a row doubles the wait, up to `maximum` (or the interval itself, if
    /// that's longer).
    public static func retryDelay(interval: Duration, consecutiveFailures: Int, maximum: Duration) -> Duration {
        guard consecutiveFailures > 0 else { return interval }
        let backedOff = interval * (1 << min(consecutiveFailures, 10))
        return min(backedOff, max(interval, maximum))
    }
}

/// Why fetching usage from Anthropic failed.
public enum ClaudeCodeFetchProblem: Error, Equatable, Sendable {
    /// No Claude Code sign-in in the keychain or `~/.claude/.credentials.json`.
    case notSignedIn
    /// Claude Code's access token has expired; Claude Code renews it the next time it's used.
    case signInExpired
    /// Anthropic turned the request down with this HTTP status.
    case rejected(status: Int)
    case unreachable
    /// A response without limits Sidelight can read: the endpoint may have changed.
    case unreadable
}

/// Claude Code's sign-in, as it saves it: in the keychain item ``keychainService`` on macOS, or in
/// `~/.claude/.credentials.json` where there's no keychain. Only the access token is read; refreshing it is left
/// to Claude Code, since a refresh would replace the sign-in it holds.
public struct ClaudeCodeCredentials: Sendable {
    public static let keychainService = "Claude Code-credentials"

    public var accessToken: String
    public var expiresAt: Date?

    public init(accessToken: String, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    /// `{"claudeAiOauth": {"accessToken": …, "expiresAt": <ms since 1970>, …}}`
    public init(data: Data) throws {
        let file = try JSONDecoder().decode(CredentialsFile.self, from: data)
        guard let accessToken = file.accessToken, !accessToken.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "No Claude access token"))
        }
        self.init(accessToken: accessToken, expiresAt: file.expiresAt)
    }

    public func isExpired(at now: Date) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }
}

private struct CredentialsFile: Decodable {
    var accessToken: String?
    var expiresAt: Date?

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: AnyCodingKey.self)
        let oauth = try root.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("claudeAiOauth"))
        accessToken = oauth.lenient(String.self, "accessToken")
        expiresAt = oauth.lenientDouble("expiresAt").map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}
