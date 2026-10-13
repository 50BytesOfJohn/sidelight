import Foundation
import Testing

@testable import SidelightCore

struct OpenRouterConfigurationTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func `new widgets and details use approved defaults`() throws {
        let credits = try decode(OpenRouterCreditsSettings.self, "{}")
        #expect(credits.refresh == .minutes(15))
        #expect(credits.chart.isShown && credits.chart.days == 7 && credits.chart.scope == .account)
        let models = try decode(OpenRouterModelsSettings.self, "{}")
        #expect(models.sync == .minutes(60))
        #expect(models.glance == .newest)
        let list = try #require(models.shownLists.first?.options)
        #expect(list.sort == .latestAdded && list.filter == .textOutput)
        #expect(list.density == .standard && list.maximumRows == 5)
        let details = try decode(DetailsPanelSettings.self, "{}")
        #expect(!details.usesCustomStyle)
        #expect(details.closeHotkey == Hotkey.defaultCloseDetails)
        #expect(details.closeHotkey.modifiers == [.control, .option, .command])
    }

    @Test func `unknown choices fall back and hand edited counts clamp`() throws {
        let list = try decode(
            OpenRouterModelListOptions.self,
            #"{"sort":"future","filter":"future","density":"future","maximumRows":999,"title":""}"#)
        #expect(list.sort == .latestAdded && list.filter == .textOutput && list.density == .standard)
        #expect(list.maximumRows == 20 && list.title == nil)
        let chart = try decode(OpenRouterSpendChartSettings.self, #"{"days":999,"scope":"future"}"#)
        #expect(chart.days == 30 && chart.scope == .account)
        let models = try decode(OpenRouterModelsSettings.self, #"{"sync":"future","glance":"future"}"#)
        #expect(models.sync == .minutes(60) && models.glance == .newest)
        let credits = try decode(OpenRouterCreditsSettings.self, #"{"refresh":"manual","chart":{"days":-10}}"#)
        #expect(credits.refresh == .manual && credits.chart.days == 7)
    }

    @Test func `preset changes keep repeatable list identity and hidden options`() throws {
        var models = OpenRouterModelsSettings()
        let list = models.addListBlock(.init(title: "Custom", sort: .outputPrice, filter: .all, maximumRows: 12))
        let id: UUID
        if case .list(let value) = list { id = value } else { throw TestFailure.notAList }
        models.apply(.textOnly)
        models.apply(.richList)
        models.apply(.latest)
        #expect(models.listOptions(id).title == "Custom")
        #expect(models.blocks.contains(list))
        let restored = try JSONDecoder().decode(OpenRouterModelsSettings.self, from: JSONEncoder().encode(models))
        #expect(restored == models)
        models.removeBlock(list)
        #expect(!models.blocks.contains(list))
        #expect(models.lists[id.uuidString] == nil)
        #expect(Set(OpenRouterModelsPreset.allCases.map(\.listID)).count == 3)
    }

    @Test func `unknown blocks and orphan options are discarded`() throws {
        var models = OpenRouterModelsSettings()
        let list = models.addListBlock(.init(title: "Kept"))
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(models)) as? [String: Any])
        var lists = try #require(json["lists"] as? [String: Any])
        lists[UUID().uuidString] = ["title": "Orphan"]
        json["lists"] = lists
        let restored = try JSONDecoder().decode(
            OpenRouterModelsSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored == models)
        #expect(restored.blocks.contains(list))
        #expect(OpenRouterModelsBlock(rawValue: "future") == nil)
        #expect(OpenRouterModelsBlock(rawValue: "list:bad") == nil)
    }

    @Test func `inherited details style remains live custom style survives switching off`() {
        var panel = BackgroundSettings()
        var details = DetailsPanelSettings()
        details.setUsesCustomStyle(true, startingFrom: panel)
        let saved = details.customBackground
        details.setUsesCustomStyle(false, startingFrom: panel)
        panel.grain = 0.7
        #expect(details.background(inheriting: panel) == panel)
        details.setUsesCustomStyle(true, startingFrom: panel)
        #expect(details.customBackground == saved)
        #expect(details.background(inheriting: panel) == saved)
    }

    @Test func `old top level configuration defaults new details without losing widgets`() throws {
        let config = AppConfiguration()
        var json = try #require(try JSONSerialization.jsonObject(with: config.json()) as? [String: Any])
        json["details"] = nil
        let loaded = try AppConfiguration(json: JSONSerialization.data(withJSONObject: json))
        #expect(loaded.details == DetailsPanelSettings())
        #expect(loaded.widgets == config.widgets)
    }

    @Test func `demand coalesces visible models and credits with charts only where they fit`() {
        var config = AppConfiguration()
        config.sections = [
            PanelSection(widgets: [
                WidgetInstance(settings: .openRouterModels(.init(sync: .manual))),
                WidgetInstance(settings: .openRouterModels(.init(sync: .minutes(15)))),
                WidgetInstance(settings: .openRouterCredits(.init(refresh: .minutes(5)))),
            ])
        ]
        let bar = config.openRouterDemand(panels: [.init(position: .top, density: .regular)])
        #expect(bar.catalogue == .minutes(15) && bar.balance == .minutes(5))
        #expect(bar.activity.isEmpty)
        let side = config.openRouterDemand(panels: [.init(position: .left, density: .regular)])
        #expect(side.activity[.account] == .minutes(5))
        let hidden = config.openRouterDemand(panels: [])
        #expect(hidden.isEmpty && hidden.keepsAccountData)
        var details = OpenRouterDemand(catalogue: .minutes(60))
        details.merge(hidden)
        #expect(!details.needsAccount)
    }

    @Test func `credits previews never demand private resources`() {
        var config = AppConfiguration()
        config.sections = [PanelSection(widgets: [WidgetInstance(kind: .openRouterCredits)])]
        let preview = config.openRouterDemand(panels: [], previewsEveryWidget: true)
        #expect(!preview.needsAccount)
        #expect(preview.balance == nil && preview.activity.isEmpty)
    }

    @Test func `key scope without a selection never falls back to account`() {
        var settings = OpenRouterCreditsSettings()
        settings.chart.scope = .key
        var demand = OpenRouterDemand()
        demand.add(WidgetInstance(settings: .openRouterCredits(settings)), showsCharts: true)
        #expect(demand.balance == .minutes(15))
        #expect(demand.activity.isEmpty)
        settings.chart.keyHash = String(repeating: "c", count: 64)
        demand.add(WidgetInstance(settings: .openRouterCredits(settings)), showsCharts: true)
        #expect(demand.activity[.account] == nil)
        #expect(demand.activity[.key(String(repeating: "c", count: 64))] == .minutes(15))
    }

    @Test func `non default widgets and details round trip without secrets`() throws {
        var config = AppConfiguration()
        var models = OpenRouterModelsSettings(sync: .manual, glance: .count, preset: .richList)
        models.summary.filter = .textOnly
        models.setListOptions(
            .init(
                title: "Prices", sort: .inputPrice, filter: .all,
                density: .lean, maximumRows: 20, showsRetiring: false), for: OpenRouterModelsPreset.richList.listID)
        let credits = OpenRouterCreditsSettings(
            refresh: .manual,
            chart: .init(
                isShown: true, days: 14, scope: .key,
                keyHash: String(repeating: "d", count: 64), keyName: "Fixture key"))
        config.sections = [
            PanelSection(widgets: [
                WidgetInstance(settings: .openRouterModels(models), showsInSidePanel: false),
                WidgetInstance(settings: .openRouterCredits(credits), showsInBar: false),
            ])
        ]
        var background = BackgroundSettings()
        background.grain = 0.6
        config.details = DetailsPanelSettings(usesCustomStyle: true, customBackground: background)
        config.details.closeHotkey = Hotkey(keyCode: 49, modifiers: [.control, .command], key: "Space")
        let data = try config.json()
        #expect(try AppConfiguration(json: data) == config)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("Bearer") && !text.contains("sk-or-"))
    }

    @Test(arguments: [15, 30, 60, 180, 360])
    func `advertised model sync intervals survive decoding`(minutes: Int) throws {
        let settings = try decode(OpenRouterModelsSettings.self, "{\"sync\":\(minutes)}")
        #expect(settings.sync == .minutes(minutes))
    }

    @Test func `hand edited refresh cadences clamp to offered UI ranges`() throws {
        let lowCredits = try decode(OpenRouterCreditsSettings.self, #"{"refresh":0}"#)
        let highCredits = try decode(OpenRouterCreditsSettings.self, #"{"refresh":999999}"#)
        let lowModels = try decode(OpenRouterModelsSettings.self, #"{"sync":0}"#)
        let highModels = try decode(OpenRouterModelsSettings.self, #"{"sync":999999}"#)
        #expect(lowCredits.refresh == .minutes(5))
        #expect(highCredits.refresh == .minutes(60))
        #expect(lowModels.sync == .minutes(15))
        #expect(highModels.sync == .minutes(360))
    }

    private enum TestFailure: Error { case notAList }
}
