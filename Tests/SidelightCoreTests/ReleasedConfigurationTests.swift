import Foundation
import Testing

@testable import SidelightCore

/// An app update must never reset someone's panel. Each file in `ReleasedConfigurations` was saved by that
/// release's own code, with every option it offered set away from its default (v0.1.0 and v0.1.1 save the same
/// schema as v0.1.2). Loading one and saving it again must keep everything it says; newer options may only add to
/// it. The exceptions are a retired widget kind, which is dropped on purpose (``WidgetKind/retiredRawValues``), and
/// the credentials versions before shared accounts saved in widgets, which become account references
/// (``migratedToAccounts(_:)``).
struct ReleasedConfigurationTests {
    static let releases = ["v0.1.2", "v0.2.0", "v0.2.1", "v0.3.0", "v0.4.0", "v0.5.0", "v0.6.0"]

    @Test(arguments: releases)
    func `a released configuration loads with every setting kept`(release: String) throws {
        let released = try Self.load(release)
        let saved = try AppConfiguration(json: released).json()
        let kept = try Self.values(in: JSONSerialization.jsonObject(with: saved))
        let expected = try Self.migratedToAccounts(
            Self.withoutRetiredWidgets(JSONSerialization.jsonObject(with: released)))
        let changed = Self.values(in: expected).filter { path, value in kept[path] != value }
        #expect(changed.isEmpty, "Lost or changed: \(changed.keys.sorted())")
    }

    @Test(arguments: releases)
    func `saving a released configuration never writes the old credential settings again`(release: String) throws {
        let saved = try String(decoding: AppConfiguration(json: Self.load(release)).json(), as: UTF8.self)
        #expect(!saved.contains("usesOwnKey"))
        for old in ["automatic", "cli", "token"] { #expect(!saved.contains(#""account" : "\#(old)""#)) }
    }

    @Test func `the retired Agent activity widget is the only one dropped`() throws {
        let url = try #require(
            Bundle.module.url(forResource: "v0.2.0", withExtension: "json", subdirectory: "ReleasedConfigurations"))
        let released = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let sections = try #require(released["sections"] as? [[String: Any]])
        let kinds = sections.flatMap { ($0["widgets"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String } }
        #expect(kinds.contains("agents"))
        let loaded = try AppConfiguration(json: Data(contentsOf: url))
        #expect(loaded.widgets.map(\.kind.rawValue) == kinds.filter { $0 != "agents" })
    }

    static func load(_ release: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: release, withExtension: "json", subdirectory: "ReleasedConfigurations"))
        return try Data(contentsOf: url)
    }

    private static func withoutRetiredWidgets(_ json: Any) -> Any {
        switch json {
        case let object as [String: Any]:
            return object.mapValues(withoutRetiredWidgets)
        case let array as [Any]:
            return array.filter { element in
                ((element as? [String: Any])?["kind"] as? String).map { !WidgetKind.retiredRawValues.contains($0) }
                    ?? true
            }
            .map(withoutRetiredWidgets)
        default:
            return json
        }
    }

    /// `json` with the credential settings of versions before shared accounts as they load now: a Balance block's
    /// `usesOwnKey` becomes a reference to the account its key moves to, and a Railway widget's `account` choice a
    /// reference (`cli` the Railway CLI, `token` the account the token moves to) or none (`automatic`).
    private static func migratedToAccounts(_ json: Any) -> Any {
        guard var root = json as? [String: Any], let sections = root["sections"] as? [[String: Any]] else {
            return json
        }
        root["sections"] = sections.map { section in
            var section = section
            section["widgets"] = (section["widgets"] as? [[String: Any]] ?? []).map(migratedWidget)
            return section
        }
        return root
    }

    private static func migratedWidget(_ widget: [String: Any]) -> [String: Any] {
        guard var settings = widget["settings"] as? [String: Any], let id = (widget["id"] as? String).flatMap(UUID.init)
        else { return widget }
        var widget = widget
        switch widget["kind"] as? String {
        case "openRouter":
            var balances = settings["balances"] as? [String: [String: Any]] ?? [:]
            for (key, var options) in balances {
                if options.removeValue(forKey: "usesOwnKey") as? Bool == true, let block = UUID(uuidString: key) {
                    options["account"] = AccountID.migratedOpenRouterKey(widget: id, block: block).rawValue
                }
                balances[key] = options
            }
            if settings["balances"] != nil { settings["balances"] = balances }
        case "railway":
            switch settings.removeValue(forKey: "account") as? String {
            case "cli": settings["account"] = AccountID.railwayCLI.rawValue
            case "token": settings["account"] = AccountID.migratedRailwayToken.rawValue
            default: break
            }
        default:
            return widget
        }
        widget["settings"] = settings
        return widget
    }

    /// Every value in a JSON document, by its path, such as `sections.<id>.widgets.<id>.settings.style`. Elements
    /// with an `id` are found by it, so a dropped widget doesn't move the ones after it.
    private static func values(in json: Any, at path: String = "") -> [String: NSObject] {
        func child(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }
        switch json {
        case let object as [String: Any]:
            return object.reduce(into: [:]) { $0.merge(values(in: $1.value, at: child($1.key))) { $1 } }
        case let array as [Any]:
            let ids = array.compactMap { ($0 as? [String: Any])?["id"] as? String }
            let order: [String: NSObject] = ids.isEmpty ? [:] : [child("$order"): ids as NSArray]
            return array.enumerated().reduce(into: order) { result, element in
                let key = ((element.element as? [String: Any])?["id"] as? String) ?? "\(element.offset)"
                result.merge(values(in: element.element, at: child(key))) { $1 }
            }
        default:
            return [path: json as? NSObject ?? NSNull()]
        }
    }
}

/// How the credentials of versions before shared accounts become accounts, one row of the migration table at a time.
struct AccountMigrationTests {
    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    private func openRouterWidget(_ balances: [String: [String: Any]]) throws -> AppConfiguration {
        try configuration(widgets: [
            [
                "id": Self.id(19).uuidString, "kind": "openRouter", "showsInBar": true, "showsInSidePanel": true,
                "settings": [
                    "blocks": balances.keys.map { ["block": "balance:\($0)", "shown": true] },
                    "balances": balances,
                ],
            ]
        ])
    }

    private func railwayWidget(account: String) throws -> AppConfiguration {
        try configuration(widgets: [
            [
                "id": Self.id(13).uuidString, "kind": "railway", "showsInBar": true, "showsInSidePanel": true,
                "settings": ["account": account],
            ]
        ])
    }

    private func configuration(widgets: [[String: Any]]) throws -> AppConfiguration {
        var json = try #require(try JSONSerialization.jsonObject(with: AppConfiguration().json()) as? [String: Any])
        json["accounts"] = nil
        json["defaultAccounts"] = nil
        json["sections"] = [["id": Self.id(901).uuidString, "widgets": widgets, "alignment": "start"]]
        return try AppConfiguration(json: JSONSerialization.data(withJSONObject: json))
    }

    private func legacy(_ source: LegacySecret.Source, in configuration: AppConfiguration) throws -> LegacySecret {
        try #require(configuration.legacySecrets.first { $0.source == source })
    }

    @Test func `a saved shared OpenRouter key becomes the default account named OpenRouter`() throws {
        var configuration = AppConfiguration()
        configuration.adopt(try legacy(.openRouterShared, in: configuration))
        #expect(
            configuration.accounts == [
                Account(id: .migratedOpenRouterKey, provider: .openRouter, name: "OpenRouter", kind: .key)
            ])
        #expect(configuration.defaultAccounts == [.openRouter: .migratedOpenRouterKey])
    }

    @Test func `a Balance block's own key becomes an account named after the block, which it names`() throws {
        let block = Self.id(503)
        var configuration = try openRouterWidget([
            block.uuidString: ["title": "Personal", "usesOwnKey": true]
        ])
        let expected = AccountID.migratedOpenRouterKey(widget: Self.id(19), block: block)
        #expect(configuration.references(to: expected) == 1)
        let own = try legacy(.openRouterBlock(widget: Self.id(19), block: block), in: configuration)
        #expect(own.account == Account(id: expected, provider: .openRouter, name: "Personal", kind: .key))
        configuration.adopt(own)
        configuration.adopt(own)
        #expect(configuration.accounts == [own.account])
        #expect(configuration.defaultAccounts.isEmpty)
    }

    @Test func `an untitled block's own key is named after the widget`() throws {
        let configuration = try openRouterWidget([Self.id(503).uuidString: ["usesOwnKey": true]])
        let own = try legacy(.openRouterBlock(widget: Self.id(19), block: Self.id(503)), in: configuration)
        #expect(own.account.name == "OpenRouter key")
    }

    @Test func `blocks that read the shared key name no account`() throws {
        let configuration = try openRouterWidget([
            Self.id(503).uuidString: ["usesOwnKey": false], Self.id(504).uuidString: [:],
        ])
        guard case .openRouter(let settings) = configuration.widgets.first?.settings else { throw Failure.wrongKind }
        #expect(settings.allBalances.allSatisfy { $0.options.account == nil })
        #expect(configuration.legacySecrets.map(\.source) == [.openRouterShared, .railwayToken])
    }

    @Test func `a block whose own key isn't there goes back to the default`() throws {
        var configuration = try openRouterWidget([Self.id(503).uuidString: ["usesOwnKey": true]])
        let own = try legacy(.openRouterBlock(widget: Self.id(19), block: Self.id(503)), in: configuration)
        configuration.drop(own)
        #expect(configuration.references(to: own.account.id) == 0 && configuration.accounts.isEmpty)
        #expect(configuration.legacySecrets.count == 2)
    }

    @Test(arguments: [("automatic", nil), ("cli", AccountID.railwayCLI), ("token", AccountID.migratedRailwayToken)])
    func `a Railway widget's choice becomes an account reference`(saved: String, reference: AccountID?) throws {
        let configuration = try railwayWidget(account: saved)
        guard case .railway(let settings) = configuration.widgets.first?.settings else { throw Failure.wrongKind }
        #expect(settings.account == reference)
    }

    @Test func `the Railway token becomes an account named Railway, not the default`() throws {
        var configuration = try railwayWidget(account: "token")
        let token = try legacy(.railwayToken, in: configuration)
        configuration.adopt(token)
        #expect(
            configuration.accounts == [
                Account(id: .migratedRailwayToken, provider: .railway, name: "Railway", kind: .key)
            ])
        #expect(configuration.defaultAccounts.isEmpty)
        #expect(configuration.resolveAccount(nil, at: .railway, signedIn: [.railwayCLI]) == .account(.railwayCLI))
    }

    @Test func `a Railway widget set to the token goes back to the default without one`() throws {
        var configuration = try railwayWidget(account: "token")
        configuration.drop(try legacy(.railwayToken, in: configuration))
        guard case .railway(let settings) = configuration.widgets.first?.settings else { throw Failure.wrongKind }
        #expect(settings.account == nil)
    }

    @Test func `migrating v0.6.0 points every widget at the right account, the same every time`() throws {
        let first = try AppConfiguration(json: ReleasedConfigurationTests.load("v0.6.0"))
        let again = try AppConfiguration(json: first.json())
        #expect(again == first)

        let widgets = Dictionary(uniqueKeysWithValues: first.widgets.map { ($0.id, $0.settings) })
        guard case .railway(let token) = widgets[Self.id(13)], case .railway(let cli) = widgets[Self.id(14)],
            case .openRouter(let credits) = widgets[Self.id(19)]
        else { throw Failure.wrongKind }
        #expect(token.account == .migratedRailwayToken)
        #expect(cli.account == .railwayCLI)
        let personal = AccountID.migratedOpenRouterKey(widget: Self.id(19), block: Self.id(503))
        #expect(credits.balanceOptions(Self.id(503)).account == personal)
        #expect(credits.balanceOptions(OpenRouterPreset.balanceID).account == nil)
        // No account until its secret has moved.
        #expect(first.accounts.isEmpty && first.defaultAccounts.isEmpty)

        var migrated = first
        for secret in first.legacySecrets { migrated.adopt(secret) }
        #expect(migrated.accounts.map(\.name) == ["OpenRouter", "Railway", "Personal"])
        #expect(migrated.defaultAccounts == [.openRouter: .migratedOpenRouterKey])
        #expect(migrated.resolveAccount(nil, at: .openRouter) == .account(.migratedOpenRouterKey))
        #expect(migrated.resolveAccount(personal, at: .openRouter) == .account(personal))
        #expect(try AppConfiguration(json: migrated.json()) == migrated)
    }

    @Test func `removing an account sends the widgets that named it back to the default`() throws {
        var configuration = try AppConfiguration(json: ReleasedConfigurationTests.load("v0.6.0"))
        for secret in configuration.legacySecrets { configuration.adopt(secret) }
        let personal = AccountID.migratedOpenRouterKey(widget: Self.id(19), block: Self.id(503))
        #expect(configuration.uses(of: personal) == 1)
        // The default serves the preset block, which names none.
        #expect(configuration.uses(of: .migratedOpenRouterKey) == 1)
        configuration.removeAccount(personal)
        #expect(configuration.references(to: personal) == 0)
        #expect(configuration.uses(of: .migratedOpenRouterKey) == 2)
        configuration.removeAccount(.migratedOpenRouterKey)
        #expect(configuration.defaultAccounts.isEmpty)
    }

    @Test func `removing the default of several accounts makes the first left the default`() {
        var configuration = AppConfiguration()
        let accounts = (1...3).map { Account.key(.openRouter, name: "Account \($0)") }
        configuration.accounts = accounts
        configuration.defaultAccounts = [.openRouter: accounts[1].id]
        configuration.removeAccount(accounts[1].id)
        #expect(configuration.defaultAccounts == [.openRouter: accounts[0].id])
    }

    private enum Failure: Error { case wrongKind }
}
