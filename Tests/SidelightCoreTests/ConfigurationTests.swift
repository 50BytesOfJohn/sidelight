import Foundation
import Testing

@testable import SidelightCore

struct ConfigurationCodingTests {
    @Test func `round-trips through JSON`() throws {
        var pixelClock = ClockSettings(style: .pixel)
        pixelClock.pixel = PixelClockOptions(color: .green, showsUnlitPixels: false, glows: false)
        pixelClock.analog = AnalogClockOptions(dial: .numerals, showsDate: false)
        pixelClock.flip = FlipClockOptions(tiles: .paper, showsDate: false)
        pixelClock.words = WordClockOptions(typeface: .rounded, roundsToFiveMinutes: true, showsDate: false)
        pixelClock.binary = BinaryClockOptions(color: .text, showsDigits: false)
        pixelClock.alignment = .trailing
        var configuration = AppConfiguration()
        configuration.panel = PanelDefaults(
            position: .bottom, width: .points(360), length: .fit, alignment: .end, shownOn: .all)
        configuration.appearance.background.kind = .image
        configuration.appearance.background.image.path = "/Users/me/Pictures/wall.jpg"
        configuration.appearance.background.color.gradient = [
            .white, RGBAColor(red: 1, green: 0, blue: 0.5, alpha: 0.5),
        ]
        configuration.appearance.cards.style = .glass
        configuration.appearance.cards.showsTitles = false
        configuration.appearance.text = .dark
        configuration.hotkey = Hotkey(keyCode: 49, modifiers: [.control, .option], key: "Space")
        configuration.updates = UpdateSettings(checksAutomatically: false, installsAutomatically: true)
        configuration.sections = [
            PanelSection(
                name: "Top",
                widgets: [
                    WidgetInstance(settings: .clock(ClockSettings(showsSeconds: true, uses24HourTime: false))),
                    WidgetInstance(settings: .clock(pixelClock)),
                    WidgetInstance(settings: .agents, showsInSidePanel: false),
                ],
                share: 2, alignment: .end),
            PanelSection(
                widgets: [WidgetInstance(settings: .system(SystemStatsSettings(metrics: .memory)))], share: nil),
            PanelSection(alignment: .center),
        ]
        configuration.displays = [
            DisplayProfile(id: "built-in", name: "Built-in Retina Display", showsPanel: false),
            DisplayProfile(id: "external", name: "Studio Display", position: .top, width: .percent(30)),
            DisplayProfile(id: "projector", name: "Projector", length: .fit, alignment: .start),
        ]

        #expect(try AppConfiguration(json: configuration.json()) == configuration)
    }

    @Test func `widgets store only their own kind's settings`() throws {
        var configuration = AppConfiguration()
        configuration.sections = [
            PanelSection(widgets: [WidgetInstance(kind: .calendar), WidgetInstance(kind: .agents)])
        ]
        let json = try #require(try JSONSerialization.jsonObject(with: configuration.json()) as? [String: Any])
        let sections = try #require(json["sections"] as? [[String: Any]])
        let widgets = try #require(sections.first?["widgets"] as? [[String: Any]])

        #expect(widgets[0]["settings"] as? [String: Int] == ["eventCount": 3])
        #expect(widgets[1]["settings"] == nil)
    }

    @Test(arguments: [
        "{",
        #"{"position": "left"}"#,
        #"{"position": "diagonal"}"#,
    ])
    func `rejects files that aren't a complete configuration`(json: String) {
        #expect(throws: (any Error).self) { try AppConfiguration(json: Data(json.utf8)) }
    }

    @Test func `cards saved before titles could be hidden keep showing them`() throws {
        // `appearance.cards` as v0.1.2 wrote it.
        let json = """
            {
              "fill": {"amount": 0.06, "color": "#FFFFFF"},
              "style": "glass",
              "tint": {"amount": 0.2, "color": "#000000"}
            }
            """
        let cards = try JSONDecoder().decode(CardSettings.self, from: Data(json.utf8))

        #expect(cards.style == .glass)
        #expect(cards.tint == Tint(color: .black, amount: 0.2))
        #expect(cards.showsTitles)
    }

    @Test func `clocks saved before alignment and the newer faces keep their look`() throws {
        // A clock's settings as v0.1.2 wrote them.
        let json = """
            {
              "analog": {"dial": "numerals", "showsDate": false},
              "pixel": {"color": "green", "glows": false, "showsUnlitPixels": true},
              "showsSeconds": true,
              "style": "pixel",
              "uses24HourTime": false
            }
            """
        let clock = try JSONDecoder().decode(ClockSettings.self, from: Data(json.utf8))

        #expect(clock.style == .pixel)
        #expect(clock.showsSeconds)
        #expect(!clock.uses24HourTime)
        #expect(clock.analog == AnalogClockOptions(dial: .numerals, showsDate: false))
        #expect(clock.pixel == PixelClockOptions(color: .green, showsUnlitPixels: true, glows: false))
        #expect(clock.alignment == .leading)
        #expect(clock.flip == FlipClockOptions())
        #expect(clock.words == WordClockOptions())
        #expect(clock.binary == BinaryClockOptions())
    }

    @Test func `only faces that can show seconds redraw every second`() {
        var clock = ClockSettings(style: .words, showsSeconds: true)
        #expect(!clock.showsSecondsOnFace)
        clock.style = .binary
        #expect(clock.showsSecondsOnFace)
    }

    @Test func `rejects unknown widget kinds`() throws {
        var json = try #require(
            try JSONSerialization.jsonObject(with: AppConfiguration().json()) as? [String: Any]
        )
        let weather: [String: Any] = [
            "id": UUID().uuidString, "kind": "weather", "showsInSidePanel": true, "showsInBar": true,
        ]
        json["sections"] = [["id": UUID().uuidString, "widgets": [weather], "share": 1, "alignment": "start"]]
        let data = try JSONSerialization.data(withJSONObject: json)

        #expect(throws: (any Error).self) { try AppConfiguration(json: data) }
    }
}

struct AppConfigurationTests {
    @Test(arguments: [PanelPosition.left, .right, .top, .bottom])
    func `visible widgets respect placement`(position: PanelPosition) {
        var configuration = AppConfiguration()
        configuration.sections = [
            PanelSection(widgets: [WidgetInstance(settings: .agents, showsInSidePanel: true, showsInBar: false)]),
            PanelSection(widgets: [WidgetInstance(settings: .nowPlaying, showsInSidePanel: false, showsInBar: true)]),
        ]
        #expect(configuration.visibleWidgetKinds(at: [position]) == (position.isBar ? [.nowPlaying] : [.agents]))
        #expect(configuration.visibleWidgetKinds(at: [.left, .top]) == [.agents, .nowPlaying])
    }

    @Test func `duplicating a widget keeps its settings but not its identity`() {
        let original = WidgetInstance(
            settings: .calendar(CalendarSettings(eventCount: 7)),
            showsInSidePanel: false
        )
        let copy = original.duplicated()
        #expect(copy.id != original.id)
        #expect(copy.settings == original.settings)
        #expect(copy.showsInSidePanel == original.showsInSidePanel)
    }
}

struct HotkeyTests {
    @Test func `display string uses Apple's modifier order`() {
        let hotkey = Hotkey(keyCode: 1, modifiers: [.command, .shift, .option, .control], key: "S")
        #expect(hotkey.displayString == "⌃⌥⇧⌘S")
    }

    @Test func `shift alone is not a valid global shortcut`() {
        #expect(!Hotkey(keyCode: 1, modifiers: [.shift], key: "S").isValid)
        #expect(Hotkey.defaultToggle.isValid)
    }
}
