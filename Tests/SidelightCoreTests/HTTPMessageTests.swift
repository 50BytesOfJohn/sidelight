import Foundation
import Testing

@testable import SidelightCore

struct HTTPRequestTests {
    @Test func `parses a complete request`() {
        let raw = "POST /event?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 4\r\n\r\nbody"
        #expect(
            HTTPRequest.parse(Data(raw.utf8))
                == .complete(
                    HTTPRequest(
                        method: "POST",
                        path: "/event",
                        headers: ["host": "127.0.0.1", "content-length": "4"],
                        body: Data("body".utf8)
                    )
                )
        )
    }

    @Test(arguments: [
        "POST /event HTTP/1.1\r\nContent-Length: 4",
        "POST /event HTTP/1.1\r\nContent-Length: 4\r\n\r\nbo",
    ])
    func `waits for more bytes`(raw: String) {
        #expect(HTTPRequest.parse(Data(raw.utf8)) == .incomplete)
    }

    @Test(arguments: [
        "garbage\r\n\r\n",
        "POST /event HTTP/1.1\r\nContent-Length: nope\r\n\r\n",
        "POST /event HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n",
    ])
    func `rejects malformed requests`(raw: String) {
        #expect(HTTPRequest.parse(Data(raw.utf8)) == .invalid)
    }

    @Test func `rejects oversized headers`() {
        let raw = "POST /event HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPRequest.maximumHeaderSize)
        #expect(HTTPRequest.parse(Data(raw.utf8)) == .invalid)
    }

    @Test func `ignores bytes past the declared body`() {
        let raw = "POST / HTTP/1.1\r\nContent-Length: 2\r\n\r\nokEXTRA"
        guard case .complete(let request) = HTTPRequest.parse(Data(raw.utf8)) else {
            Issue.record("expected a complete request")
            return
        }
        #expect(request.body == Data("ok".utf8))
    }

    @Test func `serializes a response`() {
        let text = String(decoding: HTTPResponse.ok().serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: 11\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{\"ok\":true}"))
    }
}

struct AgentEventTests {
    @Test func `decodes a payload`() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let event = try AgentEvent(
            json: Data(#"{"source":"claude-code","status":"waiting","message":"Needs input"}"#.utf8),
            receivedAt: date
        )
        #expect(event.source == "claude-code")
        #expect(event.status == .waiting)
        #expect(event.summary == "Needs input")
        #expect(event.date == date)
    }

    @Test func `every field is optional`() throws {
        let event = try AgentEvent(json: Data("{}".utf8), receivedAt: .now)
        #expect(event.source == "?")
        #expect(event.status == .other("?"))
        #expect(event.summary == "?")
    }

    @Test func `rejects non-JSON bodies`() {
        #expect(throws: (any Error).self) { try AgentEvent(json: Data("hello".utf8), receivedAt: .now) }
    }
}
