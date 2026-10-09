import Foundation
import Testing

@testable import SidelightCore

struct DisplaySettingsTests {
    @Test func `displays without overrides use the defaults`() {
        var configuration = AppConfiguration()
        configuration.panel = PanelDefaults(position: .right, width: .preset(.compact), shownOn: .main)

        #expect(
            configuration.panel(onDisplay: "a", isMain: true)
                == DisplayPanel(showsPanel: true, position: .right, width: .preset(.compact)))
        #expect(!configuration.panel(onDisplay: "b", isMain: false).showsPanel)

        configuration.panel.shownOn = .all
        #expect(configuration.panel(onDisplay: "b", isMain: false).showsPanel)
    }

    @Test func `overrides replace only the settings they set`() {
        var configuration = AppConfiguration()
        configuration.panel = PanelDefaults(position: .left, width: .points(400), shownOn: .all)
        configuration.displays = [DisplayProfile(id: "laptop", name: "Built-in", position: .top)]

        #expect(
            configuration.panel(onDisplay: "laptop", isMain: true)
                == DisplayPanel(showsPanel: true, position: .top, width: .points(400)))
    }

    @Test func `length and alignment follow the defaults unless a display overrides them`() {
        var configuration = AppConfiguration()
        configuration.panel = PanelDefaults(length: .fit, alignment: .start, shownOn: .all)
        configuration.displays = [DisplayProfile(id: "studio", name: "Studio Display", alignment: .end)]

        let laptop = configuration.panel(onDisplay: "laptop", isMain: true)
        #expect(laptop.length == .fit)
        #expect(laptop.alignment == .start)
        let studio = configuration.panel(onDisplay: "studio", isMain: false)
        #expect(studio.length == .fit)
        #expect(studio.alignment == .end)

        configuration.displays = [DisplayProfile(id: "studio", name: "Studio Display", length: .fill)]
        #expect(configuration.panel(onDisplay: "studio", isMain: false).length == .fill)
    }

    @Test func `length and alignment overrides keep a profile`() {
        var configuration = AppConfiguration()
        configuration.updateDisplayProfile(id: "a", name: "A") { $0.length = .fit }
        configuration.updateDisplayProfile(id: "b", name: "B") { $0.alignment = .end }
        #expect(configuration.displays.map(\.id) == ["a", "b"])

        configuration.updateDisplayProfile(id: "a", name: "A") { $0.length = nil }
        #expect(configuration.displays.map(\.id) == ["b"])
    }

    @Test func `a profile that no longer overrides anything is dropped`() {
        var configuration = AppConfiguration()
        configuration.updateDisplayProfile(id: "a", name: "Built-in") { $0.width = .preset(.minimal) }
        #expect(configuration.displays == [DisplayProfile(id: "a", name: "Built-in", width: .preset(.minimal))])

        configuration.updateDisplayProfile(id: "a", name: "Built-in Retina") { $0.width = nil }
        #expect(configuration.displays.isEmpty)
    }

    @Test func `setting from a display changes its override if it has one, otherwise the default`() {
        var configuration = AppConfiguration()
        configuration.set(.top, default: \.position, override: \.position, onDisplay: "a", name: "A")
        #expect(configuration.panel.position == .top)
        #expect(configuration.displays.isEmpty)

        configuration.displays = [DisplayProfile(id: "a", name: "A", position: .right)]
        configuration.set(.bottom, default: \.position, override: \.position, onDisplay: "a", name: "A")
        #expect(configuration.panel.position == .top)
        #expect(configuration.displayProfile(id: "a")?.position == .bottom)
    }

    @Test func `showing or hiding keeps an override only where it differs from the default`() {
        var configuration = AppConfiguration()
        configuration.setShowsPanel(false, onDisplay: "main", name: "Main", isMain: true)
        #expect(configuration.displayProfile(id: "main")?.showsPanel == false)

        configuration.setShowsPanel(true, onDisplay: "main", name: "Main", isMain: true)
        #expect(configuration.displays.isEmpty)
    }

    @Test func `overrides that aren't set are left out of the file`() throws {
        let profile = DisplayProfile(id: "a", name: "Built-in", width: .preset(.compact))
        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        #expect(Set(json.keys) == ["id", "name", "width"])
    }
}
