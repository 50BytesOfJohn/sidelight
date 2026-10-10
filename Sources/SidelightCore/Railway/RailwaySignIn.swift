import Foundation

/// The Railway CLI's sign-in, as `railway login` keeps it in `~/.railway/config.json`: an OAuth access token that
/// lasts an hour, which the CLI renews itself whenever it runs.
///
/// Only read, never refreshed or written. Railway rotates the refresh token on every renewal and revokes the whole
/// sign-in when a used one comes back, so a second party renewing it would sign the CLI out. When the token runs
/// out, Sidelight runs the CLI and lets it renew it (``renewalArguments``). Its description leaves the token out,
/// so it can't end up in a log.
public struct RailwayCLISignIn: Sendable, CustomStringConvertible {
    public static var configFile: URL {
        URL.homeDirectory.appending(path: ".railway/config.json", directoryHint: .notDirectory)
    }

    /// Where the CLI may be installed: its own installer's folder, then Homebrew's and friends'.
    public static var executableDirectories: [URL] {
        [URL.homeDirectory.appending(path: ".railway/bin", directoryHint: .isDirectory)]
            + ExecutableLocator.standardDirectories
    }

    /// A quick, read-only command that sends a request, so the CLI renews an expired token first.
    public static let renewalArguments = ["whoami", "--json"]

    /// The CLI renews a token this close to expiring, and no earlier.
    public static let renewalMargin: TimeInterval = 60

    public var accessToken: String
    /// `nil` for the long-lived token older CLIs saved.
    public var expiresAt: Date?

    /// `nil` when the CLI isn't signed in.
    public init?(configJSON: Data) {
        guard let config = try? JSONDecoder().decode(Config.self, from: configJSON), let user = config.user else {
            return nil
        }
        if let token = user.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            accessToken = token
            expiresAt = user.tokenExpiresAt.map { Date(timeIntervalSince1970: $0) }
        } else if let token = user.token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            accessToken = token
            expiresAt = nil
        } else {
            return nil
        }
    }

    /// Whether the CLI would renew it if run now.
    public func needsRenewal(at now: Date) -> Bool {
        expiresAt.map { now >= $0.addingTimeInterval(-Self.renewalMargin) } ?? false
    }

    /// Whether it's still good for a request sent now.
    public func isUsable(at now: Date) -> Bool {
        expiresAt.map { now < $0.addingTimeInterval(-10) } ?? true
    }

    public var description: String {
        "RailwayCLISignIn(expiresAt: \(String(describing: expiresAt)))"
    }

    private struct Config: Decodable {
        struct User: Decodable {
            var accessToken: String?
            var tokenExpiresAt: Double?
            /// Older CLIs' long-lived token.
            var token: String?
        }

        var user: User?
    }
}

/// Railway's status page: the incidents and maintenance going on now.
public enum RailwayStatusPage {
    /// `nil` when the page can't be read.
    public static func incidents(from body: Data) -> [Railway.Incident]? {
        guard let page = try? JSONDecoder().decode(Page.self, from: body) else { return nil }
        let incidents = (page.activeIncidents ?? []).map { $0.incident(isMaintenance: false) }
        let maintenance = (page.maintenances ?? []).filter(\.isOngoing).map { $0.incident(isMaintenance: true) }
        return incidents + maintenance
    }

    private struct Page: Decodable {
        var activeIncidents: [Entry]?
        var maintenances: [Entry]?
    }

    private struct Entry: Decodable {
        struct Component: Decodable {
            var name: String?
        }

        var id: String
        var title: String?
        var name: String?
        var status: String?
        var createdAt: String?
        var startsAt: String?
        var components: [Component]?

        /// Maintenance is listed while scheduled, in progress and recently done; only in progress counts.
        var isOngoing: Bool {
            let status = status?.uppercased() ?? ""
            return !["COMPLETED", "RESOLVED", "SCHEDULED", "NOT_STARTED", "CANCELLED"].contains(status)
        }

        func incident(isMaintenance: Bool) -> Railway.Incident {
            Railway.Incident(
                id: id, title: title ?? name ?? "Railway incident", status: status, isMaintenance: isMaintenance,
                startedAt: (startsAt ?? createdAt).flatMap(RailwayDate.parse),
                components: (components ?? []).compactMap(\.name))
        }
    }
}
