import Foundation

/// Requests to the providers Sidelight asks for usage and status. They carry someone's sign-in, so the session keeps
/// no cookies and caches nothing.
public enum HTTP {
    public struct Response: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data

        public init(status: Int, headers: [String: String] = [:], body: Data) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Sends `request`; throws when no response came back at all.
    @concurrent
    public static func send(_ request: URLRequest) async throws -> Response {
        let (body, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return Response(status: http?.statusCode ?? 0, headers: headers, body: body)
    }
}
