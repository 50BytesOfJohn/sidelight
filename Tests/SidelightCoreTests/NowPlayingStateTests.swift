import Foundation
import Testing

@testable import SidelightCore

struct NowPlayingStateTests {
    @Test func `a full update replaces the state`() throws {
        var state = NowPlayingState(title: "Old", artist: "Someone", playing: true)
        state.apply(try update(#"{"diff":false,"payload":{"title":"New","playing":true}}"#))
        #expect(state == NowPlayingState(title: "New", playing: true))
    }

    @Test func `a diff only touches the keys it mentions`() throws {
        var state = NowPlayingState(title: "Song", artist: "Band", playing: true)
        state.apply(try update(#"{"diff":true,"payload":{"playing":false,"artist":null}}"#))
        #expect(state == NowPlayingState(title: "Song", playing: false))
    }

    @Test func `artwork is decoded from base64`() throws {
        var state = NowPlayingState()
        let base64 = Data([1, 2, 3]).base64EncodedString()
        state.apply(try update(#"{"diff":true,"payload":{"artworkData":"\#(base64)"}}"#))
        #expect(state.artworkData == Data([1, 2, 3]))
    }

    @Test func `lines without a payload are rejected`() {
        #expect(NowPlayingUpdate.decode(Data(#"{"type":"ping"}"#.utf8)) == nil)
    }

    private func update(_ json: String) throws -> NowPlayingUpdate {
        try #require(NowPlayingUpdate.decode(Data(json.utf8)))
    }
}
