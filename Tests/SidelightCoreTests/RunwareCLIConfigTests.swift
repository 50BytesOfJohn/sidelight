import Foundation
import Testing

@testable import SidelightCore

/// Configs in the shape the Runware CLI writes (Go's `yaml.Marshal` of a flat struct), with fake keys.
struct RunwareCLIConfigTests {
    private func read(_ text: String) -> RunwareCLIConfig.Reading {
        RunwareCLIConfig.read(yaml: Data(text.utf8))
    }

    @Test(arguments: [
        "api_key: rw_TEST\n",
        "api_key: 'rw_TEST'\n",
        "api_key: \"rw_TEST\"\n",
        "api_key: rw_TEST # saved by runware auth login\n",
        "api_key: rw_TEST\r\n",
        "\u{FEFF}api_key: rw_TEST",
        "# Runware CLI\n---\noutput: json\napi_key: rw_TEST\ntransport:\n  kind: http\n",
        "api_key:   rw_TEST   \n",
    ])
    func `the key is read however the CLI may write it`(text: String) {
        #expect(read(text) == .signedIn("rw_TEST"))
    }

    @Test func `quotes keep what they escape`() {
        #expect(read("api_key: 'it''s'") == .signedIn("it's"))
        #expect(read(#"api_key: "a\"b\\c""#) == .signedIn(#"a"b\c"#))
    }

    @Test(arguments: [
        "", "output: json\n", "api_key:\n", "api_key: \"\"\n", "api_key: ''\n", "api_key: null\n", "api_key: ~\n",
        "settings:\n  api_key: rw_TEST\n", "api_key: # nothing yet\n",
    ])
    func `no key, or one nested elsewhere, is signed out`(text: String) {
        #expect(read(text) == .signedOut)
    }

    @Test(arguments: [
        "api_key: |\n  rw_TEST\n", "api_key: >\n  rw_TEST\n", "api_key: &key rw_TEST\n", "api_key: *key\n",
        "api_key: !!str rw_TEST\n", "api_key: {value: rw_TEST}\n", "api_key: [rw_TEST]\n",
        "api_key: rw_TEST\napi_key: rw_OTHER\n", #"api_key: "rw\nTEST""#, "api_key: rw TEST\n", "api_key: rw:TEST\n",
        "api_key: 'rw_TEST\n", "api_key:\n  nested: rw_TEST\n", "api_key: rw_TEST\n---\napi_key: rw_OTHER\n",
        "- api_key: rw_TEST\n", "{api_key: rw_TEST}\n", "api_key: 'rw_TEST' trailing\n",
    ])
    func `anything not read with certainty is unreadable`(text: String) {
        #expect(read(text) == .unreadable)
    }

    @Test func `invalid UTF-8 is unreadable`() {
        #expect(RunwareCLIConfig.read(yaml: Data([0x61, 0xFF, 0xFE])) == .unreadable)
    }

    @Test func `descriptions never include the key`() {
        let reading = read("api_key: rw_SECRET_TEST")
        #expect(reading.key == "rw_SECRET_TEST")
        #expect(!String(describing: reading).contains("SECRET"))
        #expect(!String(reflecting: reading).contains("SECRET"))
        #expect(!"\(reading)".contains("SECRET"))
    }

    @Test func `a missing file is signed out`() {
        let file = URL.temporaryDirectory.appending(path: "runware-\(UUID().uuidString)/config.yaml")
        #expect(RunwareCLIConfig.read(file: file) == .signedOut)
    }
}
