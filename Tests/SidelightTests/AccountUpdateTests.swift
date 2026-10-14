import Foundation
import Synchronization
import Testing

@testable import Sidelight
@testable import SidelightCore

/// Updating from v0.6.0, from the configuration file to the requests: the real configuration store, migration,
/// account store and OpenRouter service, with keys and OpenRouter standing in.
struct AccountUpdateTests {
    let directory = URL.temporaryDirectory.appending(path: "sidelight-update-\(UUID().uuidString)")
    private static let credits = UUID(uuidString: "00000000-0000-4000-8000-000000000019")!
    private static let models = UUID(uuidString: "00000000-0000-4000-8000-000000000020")!
    private static let railway = UUID(uuidString: "00000000-0000-4000-8000-000000000013")!
    private static let own = UUID(uuidString: "00000000-0000-4000-8000-000000000503")!
    private var file: URL { directory.appending(path: "config.json") }

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// As v0.6.0 saved it: a Credits widget whose second Balance block used its own key, an Overview widget whose
    /// balance read the shared key, and a Railway widget set to the token.
    private func legacyFile() throws -> Data {
        var json = try #require(try JSONSerialization.jsonObject(with: AppConfiguration().json()) as? [String: Any])
        json["accounts"] = nil
        json["defaultAccounts"] = nil
        let preset = OpenRouterPreset.balanceID.uuidString
        func widget(_ id: UUID, _ kind: String, _ settings: [String: Any]) -> [String: Any] {
            ["id": id.uuidString, "kind": kind, "showsInBar": true, "showsInSidePanel": true, "settings": settings]
        }
        json["sections"] = [
            [
                "id": UUID().uuidString, "alignment": "start",
                "widgets": [
                    widget(
                        Self.credits, "openRouter",
                        [
                            "blocks": [
                                ["block": "balance:\(preset)", "shown": true],
                                ["block": "balance:\(Self.own.uuidString)", "shown": true],
                            ],
                            "balances": [
                                preset: ["title": "Work", "usesOwnKey": false],
                                Self.own.uuidString: ["title": "Personal", "usesOwnKey": true],
                            ],
                        ]),
                    widget(
                        Self.models, "openRouter",
                        ["blocks": [["block": "balance:\(preset)", "shown": true]], "balances": [preset: [:]]]),
                    widget(Self.railway, "railway", ["account": "token"]),
                ],
            ]
        ]
        return try JSONSerialization.data(withJSONObject: json)
    }

    @Test func `every widget keeps its data, with one set of requests for each account`() async throws {
        let legacy = try legacyFile()
        try legacy.write(to: file)
        let personal = AccountID.migratedOpenRouterKey(widget: Self.credits, block: Self.own)
        let old = OldSecrets([
            .openRouterShared: "sk-or-shared", .openRouterBlock(widget: Self.credits, block: Self.own): "sk-or-own",
            .railwayToken: "railway-token",
        ])
        let new = NewSecrets()

        // First launch after the update.
        let store = ConfigurationStore(fileURL: file)
        #expect(store.configuration.widgets.map(\.id) == [Self.credits, Self.models, Self.railway])
        let keyring = AccountKeyring(secrets: new.secrets)
        let accounts = AccountStore(configuration: store, keyring: keyring)
        accounts.moveLegacySecrets(LegacySecretMigration(old: old.location, new: new.secrets))
        let requests = OpenRouterRequestLog()
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                let body =
                    request.url?.lastPathComponent == "credits"
                    ? #"{"data":{"total_credits":10,"total_usage":1}}"# : #"{"data":[]}"#
                return HTTP.Response(status: 200, body: Data(body.utf8))
            }, accounts: AccountAccess(keyring: keyring, accounts: accounts))
        await eventually { !accounts.isMovingLegacySecrets }

        // No sign-in asked for: every account is there, and the shared key's is the default.
        #expect(store.configuration.accounts.map(\.name) == ["OpenRouter", "Railway", "Personal"])
        #expect(accounts.defaultAccount(for: .openRouter) == .account(.migratedOpenRouterKey))
        #expect(accounts.resolve(nil, at: .railway) == .account(.migratedRailwayToken))
        #expect(new[personal] == "sk-or-own" && old.items.withLock { $0.isEmpty })

        service.demand = store.configuration.openRouterDemand(panels: [.init(position: .left, density: .regular)])
        service.start()
        #expect(
            await eventually {
                service.account(.migratedOpenRouterKey)?.balance.value != nil
                    && service.account(personal)?.balance.value != nil
            })
        // Three Balance blocks, two accounts: each account's balance and spending asked for once.
        let asked = requests.values.map {
            "\($0.url?.lastPathComponent ?? "") \($0.value(forHTTPHeaderField: "Authorization") ?? "")"
        }
        #expect(
            asked.sorted() == [
                "activity Bearer sk-or-own", "activity Bearer sk-or-shared", "credits Bearer sk-or-own",
                "credits Bearer sk-or-shared",
            ])
        #expect(accounts.status(of: personal) == .connected)
        service.stop()

        // Saved without the old settings, the original kept aside once, nothing secret in it.
        store.flush()
        let saved = try String(decoding: Data(contentsOf: file), as: UTF8.self)
        #expect(!saved.contains("usesOwnKey") && !saved.contains("sk-or-"))
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0.hasPrefix("config.unsupported-") }
        #expect(backups.count == 1)

        // The next launch: the same, and nothing left to move.
        let restarted = ConfigurationStore(fileURL: file)
        #expect(restarted.configuration == store.configuration)
        let outcomes = await LegacySecretMigration(old: old.location, new: new.secrets).run(on: restarted)
        #expect(Set(outcomes.values) == [.moved])
        #expect(restarted.configuration == store.configuration)
    }
}
