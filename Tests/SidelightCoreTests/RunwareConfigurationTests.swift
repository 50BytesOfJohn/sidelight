import Foundation
import Testing

@testable import SidelightCore

struct RunwareConfigurationTests {
    private func settings(_ json: String) throws -> RunwareSettings {
        try JSONDecoder().decode(RunwareSettings.self, from: Data(json.utf8))
    }

    @Test func `an empty object is the defaults`() throws {
        let decoded = try settings("{}")
        #expect(decoded == RunwareSettings())
        #expect(decoded.preset == .overview && decoded.refresh == .minutes(5))
    }

    @Test func `hand-edited values are moved into range, unknown ones take defaults`() throws {
        let decoded = try settings(
            #"{"accountID": 7, "refresh": 1, "chart": {"days": 99, "metric": "joules"}, "models": {"rowCount": 0}, "#
                + #""balance": {"title": ""}}"#)
        #expect(decoded.account == nil)
        #expect(decoded.refresh == .minutes(5))
        #expect(decoded.chart == RunwareChartOptions(days: 30, metric: .spend))
        #expect(decoded.models.rowCount == 1)
        #expect(decoded.balance.title == nil)
        #expect(try settings(#"{"refresh": 999}"#).refresh == .minutes(60))
        #expect(try settings(#"{"refresh": "manual"}"#).refresh == .manual)
    }

    @Test func `settings round-trip, and presets match their blocks`() throws {
        var original = RunwareSettings(account: AccountID(rawValue: "x"), refresh: .manual, preset: .everything)
        original.balance = RunwareBalanceOptions(title: "Studio", showsFreeCredits: false)
        original.chart = RunwareChartOptions(days: 14, metric: .requests)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(RunwareSettings.self, from: data) == original)
        #expect(original.preset == .everything)
        for preset in RunwarePreset.allCases {
            var settings = RunwareSettings()
            settings.apply(preset)
            #expect(settings.preset == preset)
        }
    }

    // MARK: Demand

    private let side = ShownPanel(position: .right, density: .regular)
    private let minimal = ShownPanel(position: .right, density: .minimal)
    private let studio = Account.key(.runware, name: "Studio")

    private func configuration(_ widgets: [WidgetInstance]) -> AppConfiguration {
        var configuration = AppConfiguration()
        configuration.accounts = [studio]
        configuration.sections = [PanelSection(widgets: widgets)]
        return configuration
    }

    private func widget(
        _ preset: RunwarePreset, refresh: RefreshCadence = .minutes(5), account: AccountID? = nil
    )
        -> WidgetInstance
    {
        WidgetInstance(settings: .runware(RunwareSettings(account: account, refresh: refresh, preset: preset)))
    }

    @Test func `minimal panels need the details only, whatever blocks are shown`() {
        let demand = configuration([widget(.everything)]).runwareDemand(panels: [minimal])
        #expect(demand.accounts == [studio.id: RunwareAccountDemand(details: .minutes(5))])
    }

    @Test func `blocks decide what's fetched`() {
        let balance = configuration([widget(.balance)]).runwareDemand(panels: [side])
        #expect(balance.account(studio.id) == RunwareAccountDemand(details: .minutes(5)))
        let overview = configuration([widget(.overview)]).runwareDemand(panels: [side])
        #expect(overview.account(studio.id) == RunwareAccountDemand(details: .minutes(5), activity: .minutes(5)))
        var chartOnly = RunwareSettings()
        chartOnly.blocks.showOnly([.chart])
        let chart = configuration([WidgetInstance(settings: .runware(chartOnly))]).runwareDemand(panels: [side])
        #expect(chart.account(studio.id) == RunwareAccountDemand(activity: .minutes(5)))
    }

    @Test func `two widgets on one account make one entry at the faster cadence`() {
        let demand = configuration([widget(.balance, refresh: .minutes(30)), widget(.overview, refresh: .manual)])
            .runwareDemand(panels: [side])
        #expect(demand.accounts.count == 1)
        #expect(demand.account(studio.id) == RunwareAccountDemand(details: .minutes(30), activity: .manual))
    }

    @Test func `hidden widgets keep their account without fetching, and other kinds limit it away`() {
        var hidden = widget(.overview)
        hidden.showsInSidePanel = false
        hidden.showsInBar = false
        let demand = configuration([hidden]).runwareDemand(panels: [side])
        #expect(demand.isEmpty && !demand.isShown)
        #expect(demand.keptAccounts == [studio.id])
        let shown = configuration([widget(.overview)]).runwareDemand(panels: [side])
        #expect(shown.limited(to: [.clock]) == RunwareDemand())
        #expect(shown.limited(to: [.runware]) == shown)
    }

    @Test func `a widget without an account is still shown, so the CLI's sign-in is looked for`() {
        let demand = AppConfiguration().with([widget(.overview)]).runwareDemand(panels: [side])
        #expect(demand.isShown && demand.isEmpty && demand.keptAccounts.isEmpty)
    }

    @Test func `the signed-in CLI is the default, unless one was chosen`() {
        let configuration = configuration([widget(.overview)])
        #expect(configuration.runwareDemand(panels: [side]).accounts.keys.first == studio.id)
        let cli = configuration.runwareDemand(panels: [side], signedIn: [.runwareCLI])
        #expect(cli.accounts.keys.first == .runwareCLI)
        var chosen = configuration
        chosen.defaultAccounts = [.runware: studio.id]
        #expect(chosen.runwareDemand(panels: [side], signedIn: [.runwareCLI]).accounts.keys.first == studio.id)
    }

    @Test func `a widget naming a removed account fetches nothing`() {
        let demand = configuration([widget(.overview, account: AccountID(rawValue: "gone"))])
            .runwareDemand(panels: [side])
        #expect(demand.isEmpty && demand.isShown && demand.keptAccounts.isEmpty)
    }
}

extension AppConfiguration {
    fileprivate func with(_ widgets: [WidgetInstance]) -> AppConfiguration {
        var configuration = self
        configuration.sections = [PanelSection(widgets: widgets)]
        return configuration
    }
}

struct RunwareAccountTests {
    private let token = Account.key(.railway, name: "Token")
    private let studio = Account.key(.runware, name: "Studio")

    @Test func `Railway and Runware prefer their signed-in CLI, the others don't`() {
        #expect(AccountProvider.allCases.filter(\.prefersSignedInAppSignIn) == [.railway, .runware])
        var configuration = AppConfiguration()
        configuration.accounts = [token, studio]
        #expect(configuration.resolveAccount(nil, at: .railway, signedIn: [.railwayCLI]) == .account(.railwayCLI))
        #expect(configuration.resolveAccount(nil, at: .runware) == .account(studio.id))
        #expect(configuration.resolveAccount(nil, at: .runware, signedIn: [.runwareCLI]) == .account(.runwareCLI))
        configuration.defaultAccounts = [.runware: studio.id]
        #expect(configuration.resolveAccount(nil, at: .runware, signedIn: [.runwareCLI]) == .account(studio.id))
        #expect(configuration.account(.runwareCLI)?.name == "Runware CLI")
    }

    @Test func `Runware widgets are counted, forgotten and sent back to the default`() {
        var configuration = AppConfiguration()
        configuration.accounts = [studio]
        configuration.sections = [
            PanelSection(widgets: [
                WidgetInstance(settings: .runware(RunwareSettings(account: studio.id))),
                WidgetInstance(settings: .runware(RunwareSettings())),
            ])
        ]
        #expect(configuration.references(to: studio.id) == 1)
        #expect(configuration.uses(of: studio.id) == 2)
        configuration.removeAccount(studio.id)
        #expect(configuration.references(to: studio.id) == 0)
        #expect(
            configuration.widgets.allSatisfy { widget in
                if case .runware(let settings) = widget.settings { settings.account == nil } else { false }
            })
    }

    @Test func `suggested names count the CLI's`() {
        var configuration = AppConfiguration()
        #expect(configuration.suggestedAccountName(for: .runware) == "Runware")
        configuration.accounts = [Account.key(.runware, name: "Runware")]
        #expect(configuration.suggestedAccountName(for: .runware) == "Runware 2")
    }
}
