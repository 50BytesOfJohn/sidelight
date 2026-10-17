import Foundation
import Testing

@testable import SidelightCore

struct AwakeStateTests {
    /// A whole minute, standing in for 10:00:00.
    static let ten = Date(timeIntervalSinceReferenceDate: 60 * 30_000_000)

    static func at(minutes: Double = 0, seconds: Double = 0) -> Date {
        ten.addingTimeInterval(minutes * 60 + seconds)
    }

    @Test func `a timed session ends on the next whole minute`() {
        // Started at 10:00:20: 15 minutes would be 10:15:20, so it runs to 10:16.
        let state = AwakeState.started(.minutes(15), at: Self.at(seconds: 20))
        #expect(state == .timed(started: Self.at(seconds: 20), ends: Self.at(minutes: 16)))
    }

    @Test func `a session started on a whole minute ends exactly then`() {
        let state = AwakeState.started(.minutes(15), at: Self.ten)
        #expect(state.ends == Self.at(minutes: 15))
    }

    @Test func `an indefinite session has no end`() {
        let state = AwakeState.started(.indefinitely, at: Self.ten)
        #expect(state == .indefinite && state.isActive)
        #expect(state.remaining(at: Self.ten) == nil && state.progress(at: Self.ten) == nil)
        #expect(state.shortRemaining(at: Self.ten) == nil)
    }

    /// Seconds left, and how they read.
    static let remainingTexts: [(TimeInterval, String)] = [
        (42 * 60, "42m"), (65 * 60, "1h 5m"), (120 * 60, "2h"), (10, "1m"), (41 * 60 + 30, "42m"), (0, "1m"),
    ]

    @Test(arguments: remainingTexts)
    func `time left reads short, a started minute counting whole`(remaining: Double, text: String) {
        let state = AwakeState.timed(started: Self.ten, ends: Self.at(minutes: 240))
        #expect(state.shortRemaining(at: Self.at(minutes: 240, seconds: -remaining)) == text)
    }

    @Test func `off has no time left`() {
        #expect(AwakeState.off.shortRemaining(at: Self.ten) == nil)
        #expect(AwakeState.off.remaining(at: Self.ten) == nil)
        #expect(!AwakeState.off.isActive)
    }

    @Test func `progress runs from one to zero and stays in range`() {
        let state = AwakeState.timed(started: Self.ten, ends: Self.at(minutes: 10))
        #expect(state.progress(at: Self.ten) == 1)
        #expect(state.progress(at: Self.at(minutes: 5)) == 0.5)
        #expect(state.progress(at: Self.at(minutes: 20)) == 0)
        #expect(state.progress(at: Self.at(minutes: -5)) == 1)
        #expect(state.remaining(at: Self.at(minutes: 20)) == 0)
    }

    @Test func `the menu offers durations in Title Case`() {
        #expect(
            AwakeChoice.presets.map(\.title) == [
                "For 15 Minutes", "For 30 Minutes", "For 1 Hour", "For 2 Hours", "For 4 Hours", "Indefinitely",
            ])
    }
}

struct AwakeConfigurationTests {
    @Test func `options missing or unreadable take their defaults`() throws {
        for json in ["{}", #"{"keepsDisplayOn": "yes"}"#] {
            let options = try JSONDecoder().decode(AwakeOptions.self, from: Data(json.utf8))
            #expect(options == AwakeOptions())
        }
        let on = try JSONDecoder().decode(AwakeOptions.self, from: Data(#"{"keepsDisplayOn": true}"#.utf8))
        #expect(on.keepsDisplayOn)
    }

    @Test func `a configuration without awake options loads, and keeps them once set`() throws {
        var configuration = AppConfiguration()
        configuration.windowAvoidance = .clip
        var file = try #require(try JSONSerialization.jsonObject(with: configuration.json()) as? [String: Any])
        #expect(file["awake"] != nil)
        file["awake"] = nil
        let read = try AppConfiguration(json: JSONSerialization.data(withJSONObject: file))
        #expect(read == configuration)

        configuration.awake.keepsDisplayOn = true
        #expect(try AppConfiguration(json: configuration.json()) == configuration)
    }

    @Test func `an Awake widget round-trips with its style`() throws {
        for style in AwakeStyle.allCases {
            let widget = WidgetInstance(settings: .awake(AwakeSettings(style: style)))
            let data = try JSONEncoder().encode(widget)
            let file = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(file["kind"] as? String == "awake")
            #expect(try JSONDecoder().decode(WidgetInstance.self, from: data) == widget)
        }
    }

    @Test func `an Awake widget saved without settings, as released versions did, is a tile`() throws {
        var file = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(WidgetInstance(kind: .awake)))
                as? [String: Any])
        file["settings"] = nil
        let widget = try JSONDecoder().decode(WidgetInstance.self, from: JSONSerialization.data(withJSONObject: file))
        #expect(widget.settings == .awake(AwakeSettings(style: .tile)))
    }

    @Test func `an unknown Awake style falls back to the tile`() throws {
        for json in ["{}", #"{"style": "hologram"}"#] {
            let settings = try JSONDecoder().decode(AwakeSettings.self, from: Data(json.utf8))
            #expect(settings == AwakeSettings())
        }
        let slim = try JSONDecoder().decode(AwakeSettings.self, from: Data(#"{"style": "slim"}"#.utf8))
        #expect(slim.style == .slim)
    }
}
