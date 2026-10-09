import Foundation

/// A minimal HTTP/1.1 request, just enough for the local agent-event endpoint.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    /// Path without the query string.
    public var path: String
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    /// Incremental parser over the bytes received so far.
    public enum ParseResult: Equatable, Sendable {
        /// More bytes are needed.
        case incomplete
        case complete(HTTPRequest)
        case invalid
    }

    public static let maximumHeaderSize = 16 * 1024
    public static let maximumBodySize = 1024 * 1024

    public static func parse(_ buffer: Data) -> ParseResult {
        guard let headerEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maximumHeaderSize ? .invalid : .incomplete
        }

        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).makeIterator()
        let requestLine = (lines.next() ?? "").split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/") else { return .invalid }

        var headers: [String: String] = [:]
        while let line = lines.next() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let contentLength: Int
        if let value = headers["content-length"] {
            guard let length = Int(value), (0...maximumBodySize).contains(length) else { return .invalid }
            contentLength = length
        } else {
            contentLength = 0
        }

        let body = buffer[headerEnd.upperBound...]
        guard body.count >= contentLength else { return .incomplete }

        let target = requestLine[1]
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? String(target)
        return .complete(
            HTTPRequest(
                method: String(requestLine[0]),
                path: path,
                headers: headers,
                body: Data(body.prefix(contentLength))
            )
        )
    }
}

/// A JSON response that closes the connection after sending.
public struct HTTPResponse: Equatable, Sendable {
    public enum Status: Int, Sendable {
        case ok = 200
        case badRequest = 400
        case notFound = 404
        case methodNotAllowed = 405
        case payloadTooLarge = 413

        var reasonPhrase: String {
            switch self {
            case .ok: "OK"
            case .badRequest: "Bad Request"
            case .notFound: "Not Found"
            case .methodNotAllowed: "Method Not Allowed"
            case .payloadTooLarge: "Payload Too Large"
            }
        }
    }

    public var status: Status
    public var body: Data

    public init(status: Status, jsonBody: String) {
        self.status = status
        self.body = Data(jsonBody.utf8)
    }

    public static func ok() -> HTTPResponse { HTTPResponse(status: .ok, jsonBody: #"{"ok":true}"#) }

    public static func error(_ status: Status) -> HTTPResponse {
        HTTPResponse(status: status, jsonBody: #"{"ok":false}"#)
    }

    public func serialized() -> Data {
        let head = [
            "HTTP/1.1 \(status.rawValue) \(status.reasonPhrase)",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Connection: close",
        ].joined(separator: "\r\n")
        return Data((head + "\r\n\r\n").utf8) + body
    }
}
