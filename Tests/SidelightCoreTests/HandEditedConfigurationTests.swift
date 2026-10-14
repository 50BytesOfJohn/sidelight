import Foundation
import Testing

@testable import SidelightCore

/// `config.json` is meant to be edited by hand. Whatever decodes must be safe to draw and run with.
struct HandEditedConfigurationTests {
    /// The default configuration with one section holding `widget`, as a file would have it.
    private func configuration(widget: String, share: String = "null") throws -> AppConfiguration {
        var file = try #require(try JSONSerialization.jsonObject(with: AppConfiguration().json()) as? [String: Any])
        let section = """
            {"id": "\(UUID().uuidString)", "alignment": "start", "share": \(share), "widgets": [\(widget)]}
            """
        file["sections"] = [try JSONSerialization.jsonObject(with: Data(section.utf8))]
        return try AppConfiguration(json: JSONSerialization.data(withJSONObject: file))
    }

    private func widget(kind: String, settings: String? = nil) -> String {
        let settings = settings.map { #", "settings": \#($0)"# } ?? ""
        let placement = #""showsInSidePanel": true, "showsInBar": true"#
        return #"{"id": "\#(UUID().uuidString)", "kind": "\#(kind)", \#(placement)\#(settings)}"#
    }

    @Test func `counts outside what the settings offer are moved into range`() throws {
        let negative = try configuration(widget: widget(kind: "calendar", settings: #"{"eventCount": -3}"#))
        #expect(negative.widgets.first?.settings == .calendar(CalendarSettings(eventCount: 1)))
        let huge = try configuration(widget: widget(kind: "calendar", settings: #"{"eventCount": 900}"#))
        #expect(huge.widgets.first?.settings == .calendar(CalendarSettings(eventCount: 10)))
    }

    @Test func `refresh intervals can't overflow`() throws {
        let edited = try configuration(
            widget: widget(
                kind: "claudeCode",
                settings: #"{"refreshesFromAnthropic": true, "refreshMinutes": 9223372036854775807}"#))
        guard case .claudeCode(let settings) = edited.widgets.first?.settings else {
            Issue.record("Expected Claude Code settings")
            return
        }
        #expect(settings.refreshMinutes == UsageRefresh.minuteRange.upperBound)
        let minutes = edited.claudeCodeDemand(of: edited.widgets)[.claudeCodeApp]?.refreshMinutes
        #expect(minutes.map { Duration.seconds($0 * 60) } != nil)
    }

    @Test(arguments: ["clock", "codex", "claudeCode", "cursor", "aiUsage", "calendar", "system", "railway"])
    func `a widget saved without settings takes the defaults`(kind: String) throws {
        let loaded = try configuration(widget: widget(kind: kind))
        let kind = try #require(WidgetKind(rawValue: kind))
        #expect(loaded.widgets.first?.settings == .defaults(for: kind))
    }

    @Test(arguments: ["-2", "0"])
    func `a share that isn't positive leaves the section at its natural length`(share: String) throws {
        let loaded = try configuration(widget: widget(kind: "clock"), share: share)
        #expect(loaded.sections.first?.share == nil)
    }
}
