import Foundation
import Testing

@testable import SidelightCore

struct OpenRouterConfigurationTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func `new widgets and details use approved defaults`() throws {
        let balance = try decode(OpenRouterBalanceOptions.self, "{}")
        #expect(!balance.usesOwnKey && balance.title == nil)
        #expect(balance.chart.isShown && balance.chart.days == 7 && balance.chart.scope == .account)
        let models = try decode(OpenRouterSettings.self, "{}")
        #expect(models.sync == .minutes(1440) && models.refresh == .minutes(15))
        #expect(models.shownBalances.isEmpty)
        #expect(models.glance == .automatic && models.resolvedGlance == .newest)
        #expect(OpenRouterSettings(preset: .credits).resolvedGlance == .balance)
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
        let models = try decode(OpenRouterSettings.self, #"{"sync":"future","glance":"future","refresh":"manual"}"#)
        #expect(models.sync == .minutes(1440) && models.glance == .automatic && models.refresh == .manual)
        let balance = try decode(OpenRouterBalanceOptions.self, #"{"usesOwnKey":true,"chart":{"days":-10}}"#)
        #expect(balance.usesOwnKey && balance.chart.days == 7)
    }

    @Test func `preset changes keep repeatable list identity and hidden options`() throws {
        var models = OpenRouterSettings()
        let list = models.addListBlock(.init(title: "Custom", sort: .outputPrice, filter: .all, maximumRows: 12))
        let id: UUID
        if case .list(let value) = list { id = value } else { throw TestFailure.notAList }
        models.apply(.textOnly)
        models.apply(.richList)
        models.apply(.latest)
        #expect(models.listOptions(id).title == "Custom")
        #expect(models.blocks.contains(list))
        let restored = try JSONDecoder().decode(OpenRouterSettings.self, from: JSONEncoder().encode(models))
        #expect(restored == models)
        models.removeBlock(list)
        #expect(!models.blocks.contains(list))
        #expect(models.lists[id.uuidString] == nil)
        #expect(Set(OpenRouterPreset.allCases.compactMap(\.listID)).count == 3)
    }

    @Test func `unknown blocks and orphan options are discarded`() throws {
        var models = OpenRouterSettings()
        let list = models.addListBlock(.init(title: "Kept"))
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(models)) as? [String: Any])
        var lists = try #require(json["lists"] as? [String: Any])
        lists[UUID().uuidString] = ["title": "Orphan"]
        json["lists"] = lists
        let restored = try JSONDecoder().decode(
            OpenRouterSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored == models)
        #expect(restored.blocks.contains(list))
        #expect(OpenRouterBlock(rawValue: "future") == nil)
        #expect(OpenRouterBlock(rawValue: "list:bad") == nil)
        let balance = OpenRouterBlock.balance(UUID())
        #expect(OpenRouterBlock(rawValue: balance.rawValue) == balance)
    }

    @Test func `balance blocks repeat each with options and their own account`() throws {
        var settings = OpenRouterSettings(preset: .overview)
        let presetID = OpenRouterPreset.balanceID
        settings.setBalanceOptions(.init(title: "Work"), for: presetID)
        let added = settings.addBalanceBlock(.init(title: "Personal", usesOwnKey: true))
        guard case .balance(let addedID) = added else { throw TestFailure.notAList }
        #expect(settings.shownBalances.map(\.options.title) == ["Work", "Personal"])
        let widget = UUID()
        #expect(settings.balanceOptions(presetID).account(widget: widget, block: presetID) == .shared)
        #expect(
            settings.balanceOptions(addedID).account(widget: widget, block: addedID)
                == .own(widget: widget, block: addedID))
        // Choosing a preset hides the added block but keeps it and its options.
        settings.apply(.credits)
        #expect(settings.shownBalances.map(\.id) == [presetID])
        #expect(settings.allBalances.count == 2)
        let restored = try JSONDecoder().decode(OpenRouterSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored == settings)
        settings.removeBlock(added)
        #expect(settings.allBalances.map(\.id) == [presetID])
        #expect(settings.balances[addedID.uuidString] == nil)
    }

    @Test func `orphan balance options are discarded`() throws {
        let settings = OpenRouterSettings(preset: .credits)
        var json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json["balances"] = [UUID().uuidString: ["title": "Orphan"]]
        let restored = try JSONDecoder().decode(
            OpenRouterSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.balances.isEmpty && restored == settings)
    }

    @Test func `kept accounts follow balance blocks shown or hidden and their own keys`() {
        var settings = OpenRouterSettings(preset: .overview)
        let added = settings.addBalanceBlock(.init(usesOwnKey: true))
        guard case .balance(let addedID) = added else { return }
        settings.blocks.setShown(added, false)
        let widget = WidgetInstance(settings: .openRouter(settings))
        var config = AppConfiguration()
        config.sections = [PanelSection(widgets: [widget, WidgetInstance(settings: .openRouter(.init()))])]
        #expect(config.openRouterAccounts == [.shared, .own(widget: widget.id, block: addedID)])
        let side = config.openRouterDemand(panels: [.init(position: .left, density: .regular)])
        // Hidden: kept, but nothing fetched for it.
        #expect(side.accounts.keys.sorted { "\($0)" < "\($1)" } == [.shared])
        #expect(side.keptAccounts == config.openRouterAccounts)
    }

    @Test func `the balance glance fetches only the first balance and no chart`() {
        var settings = OpenRouterSettings(glance: .balance, preset: .overview)
        settings.addBalanceBlock(.init(usesOwnKey: true))
        let widget = WidgetInstance(settings: .openRouter(settings))
        var config = AppConfiguration()
        config.sections = [PanelSection(widgets: [widget])]
        let bar = config.openRouterDemand(panels: [.init(position: .top, density: .regular)])
        #expect(bar.catalogue == nil)
        #expect(bar.accounts == [.shared: OpenRouterAccountDemand(balance: .minutes(15))])
        let side = config.openRouterDemand(panels: [.init(position: .left, density: .regular)])
        #expect(side.catalogue == .minutes(1440) && side.accounts.count == 2)
        #expect(side.account(.shared).activity[.account] == .minutes(15))
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

    @Test func `demand coalesces visible models and balances with charts only where they fit`() {
        var config = AppConfiguration()
        config.sections = [
            PanelSection(widgets: [
                WidgetInstance(settings: .openRouter(.init(sync: .manual))),
                WidgetInstance(settings: .openRouter(.init(sync: .minutes(15)))),
                WidgetInstance(settings: .openRouter(.init(refresh: .minutes(5), glance: .balance, preset: .credits))),
            ])
        ]
        let bar = config.openRouterDemand(panels: [.init(position: .top, density: .regular)])
        #expect(bar.catalogue == .minutes(15) && bar.account(.shared).balance == .minutes(5))
        #expect(bar.account(.shared).activity.isEmpty)
        let side = config.openRouterDemand(panels: [.init(position: .left, density: .regular)])
        #expect(side.account(.shared).activity[.account] == .minutes(5))
        let hidden = config.openRouterDemand(panels: [])
        #expect(hidden.isEmpty && hidden.keptAccounts == [.shared])
        var details = OpenRouterDemand(catalogue: .minutes(60))
        details.merge(hidden)
        #expect(!details.needsAccount)
    }

    @Test func `balance previews never demand private resources`() {
        var config = AppConfiguration()
        config.sections = [PanelSection(widgets: [WidgetInstance(settings: .openRouter(.init(preset: .credits)))])]
        let preview = config.openRouterDemand(panels: [], previewsEveryWidget: true)
        #expect(!preview.needsAccount && preview.catalogue == nil)
    }

    @Test func `key scope without a selection never falls back to account`() {
        var settings = OpenRouterSettings(preset: .credits)
        let id = OpenRouterPreset.balanceID
        var options = settings.balanceOptions(id)
        options.chart.scope = .key
        settings.setBalanceOptions(options, for: id)
        let side = ShownPanel(position: .left, density: .regular)
        var demand = OpenRouterDemand()
        demand.add(WidgetInstance(settings: .openRouter(settings)), on: side)
        #expect(demand.account(.shared).balance == .minutes(15))
        #expect(demand.account(.shared).activity.isEmpty)
        options.chart.keyHash = String(repeating: "c", count: 64)
        settings.setBalanceOptions(options, for: id)
        demand.add(WidgetInstance(settings: .openRouter(settings)), on: side)
        #expect(demand.account(.shared).activity[.account] == nil)
        #expect(demand.account(.shared).activity[.key(String(repeating: "c", count: 64))] == .minutes(15))
    }

    @Test func `non default widgets and details round trip without secrets`() throws {
        var config = AppConfiguration()
        var models = OpenRouterSettings(sync: .manual, glance: .count, preset: .richList)
        models.addBalanceBlock(
            .init(
                title: "Side project", usesOwnKey: true,
                chart: .init(
                    isShown: true, days: 14, scope: .key, keyHash: String(repeating: "d", count: 64),
                    keyName: "Fixture key")))
        models.summary.filter = .textOnly
        models.setListOptions(
            .init(
                title: "Prices", sort: .inputPrice, filter: .all,
                density: .lean, maximumRows: 20, showsRetiring: false),
            for: try #require(OpenRouterPreset.richList.listID))
        config.sections = [
            PanelSection(widgets: [
                WidgetInstance(settings: .openRouter(models), showsInSidePanel: false),
                WidgetInstance(settings: .openRouter(.init(refresh: .manual, preset: .credits)), showsInBar: false),
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

    @Test(arguments: [15, 30, 60, 180, 360, 720, 1440])
    func `advertised model sync intervals survive decoding`(minutes: Int) throws {
        let settings = try decode(OpenRouterSettings.self, "{\"sync\":\(minutes)}")
        #expect(settings.sync == .minutes(minutes))
    }

    @Test func `hand edited refresh cadences clamp to offered UI ranges`() throws {
        let lowCredits = try decode(OpenRouterSettings.self, #"{"refresh":0}"#)
        let highCredits = try decode(OpenRouterSettings.self, #"{"refresh":999999}"#)
        let lowModels = try decode(OpenRouterSettings.self, #"{"sync":0}"#)
        let highModels = try decode(OpenRouterSettings.self, #"{"sync":999999}"#)
        #expect(lowCredits.refresh == .minutes(5))
        #expect(highCredits.refresh == .minutes(60))
        #expect(lowModels.sync == .minutes(15))
        #expect(highModels.sync == .minutes(1440))
    }

    private enum TestFailure: Error { case notAList }
}
