import Foundation
import Synchronization
import Testing

@testable import Sidelight
@testable import SidelightCore

/// Every request is intercepted and every credential operation uses memory only.
struct OpenRouterServiceTests {
    @Test func `public demand coalesces and never reads credential store`() async {
        let requests = OpenRouterRequestLog()
        let store = OpenRouterMemoryKey()
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                return Self.response(#"{"data":[{"id":"fixture/model"}]}"#)
            }, keys: .init(shared: store.adapter))
        service.demand = OpenRouterDemand(catalogue: .manual)
        service.start()
        service.start()
        #expect(await eventually { service.catalogue.value != nil && !service.catalogue.isFetching })
        service.refreshCatalogue()
        service.stop()
        service.start()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(requests.values.count == 1)
        #expect(requests.values.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(store.reads == 0 && service.shared.hasKey == nil)
        service.stop()
    }

    @Test func `balance and chart share one credential read and stopping suppresses late answers`() async {
        let replies = Answers<HTTP.Response>()
        let store = OpenRouterMemoryKey("fixture")
        let requests = OpenRouterRequestLog()
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                return await replies.next()
            }, keys: .init(shared: store.adapter))
        service.demand = OpenRouterDemand.shared(
            balance: .manual, activity: [.account: .manual], keepsAccountData: true)
        service.start()
        #expect(await eventually { replies.pendingCount == 2 })
        #expect(store.reads == 1)
        #expect(Set(requests.values.compactMap { $0.url?.lastPathComponent }) == ["credits", "activity"])
        service.stop()
        await replies.answer(Self.response(#"{"data":{"total_credits":10,"total_usage":1}}"#))
        await replies.answer(Self.response(#"{"data":[]}"#))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(service.shared.balance.value == nil)
        #expect(service.shared.activity(for: .account)?.value == nil)
        #expect(!service.shared.balance.isFetching)
    }

    @Test func `credential removal clears cache and prevents old account answer`() async {
        let replies = Answers<HTTP.Response>()
        let store = OpenRouterMemoryKey("old-fixture")
        let service = OpenRouterService(transport: { _ in await replies.next() }, keys: .init(shared: store.adapter))
        service.demand = OpenRouterDemand.shared(balance: .manual, keepsAccountData: true)
        service.start()
        #expect(await eventually { replies.pendingCount == 1 })
        service.shared.removeKey()
        await replies.answer(Self.response(#"{"data":{"total_credits":999,"total_usage":1}}"#))
        #expect(await eventually { service.shared.balance.problem == .noKey && !service.shared.balance.isFetching })
        #expect(service.shared.balance.value == nil && service.shared.hasKey == false)
        #expect(await eventually { store.key == nil })
        service.stop()
    }

    @Test func `inference key validation never writes credential`() async {
        let store = OpenRouterMemoryKey()
        let service = OpenRouterService(
            transport: { _ in Self.response(#"{"data":{"is_management_key":false}}"#) },
            keys: .init(shared: store.adapter))
        #expect(await service.shared.saveKey("fixture") == .notManagementKey)
        #expect(store.saves == 0 && store.key == nil)
        service.stop()
    }

    @Test func `cancelled validation never saves a credential`() async {
        let replies = Answers<HTTP.Response>()
        let store = OpenRouterMemoryKey()
        let service = OpenRouterService(transport: { _ in await replies.next() }, keys: .init(shared: store.adapter))
        let saving = Task { await service.shared.saveKey("fixture") }
        #expect(await eventually { replies.pendingCount == 1 })
        saving.cancel()
        await replies.answer(Self.response(#"{"data":{"is_management_key":true}}"#))
        _ = await saving.value
        #expect(store.saves == 0 && store.key == nil)
        service.stop()
    }

    @Test func `removal overtakes validation so stale candidate never saves`() async {
        let replies = Answers<HTTP.Response>()
        let store = OpenRouterMemoryKey("before")
        let service = OpenRouterService(transport: { _ in await replies.next() }, keys: .init(shared: store.adapter))
        let saving = Task { await service.shared.saveKey("candidate") }
        #expect(await eventually { replies.pendingCount == 1 })
        service.shared.removeKey()
        await replies.answer(Self.response(#"{"data":{"is_management_key":true}}"#))
        _ = await saving.value
        #expect(await eventually { store.key == nil })
        #expect(store.saves == 0 && service.shared.hasKey == false)
        service.stop()
    }

    @Test func `key scoped activity never falls back when selected key disappeared`() async {
        let requests = OpenRouterRequestLog()
        let store = OpenRouterMemoryKey("fixture")
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                return Self.response("{}", status: 404)
            }, keys: .init(shared: store.adapter))
        let scope = OpenRouterSpendScope.key(String(repeating: "a", count: 64))
        service.demand = OpenRouterDemand.shared(activity: [scope: .manual], keepsAccountData: true)
        service.start()
        #expect(await eventually { service.shared.activity(for: scope)?.problem == .keyNotFound })
        #expect(requests.values.count == 1)
        #expect(!requests.values.contains { $0.url?.lastPathComponent == "activity" })
        #expect(service.shared.activity(for: scope)?.value == nil)
        service.stop()
    }

    @Test func `key picker deduplicates within a page and loads additional pages explicitly`() async {
        let hash = String(repeating: "a", count: 64)
        let row = "{\"hash\":\"\(hash)\",\"name\":\"Fixture\"}"
        let json = "{\"data\":[" + Array(repeating: row, count: 100).joined(separator: ",") + "]}"
        let requests = OpenRouterRequestLog()
        let store = OpenRouterMemoryKey("fixture")
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                if request.url?.query?.contains("offset=100") == true { return Self.response(#"{"data":[]}"#) }
                return Self.response(json)
            }, keys: .init(shared: store.adapter))
        service.shared.loadKeysIfNeeded()
        #expect(await eventually { service.shared.keyList.fetchedAt != nil && !service.shared.keyList.isLoading })
        #expect(service.shared.keyList.keys.count == 1)
        #expect(service.shared.keyList.hasMore)
        #expect(requests.values.count == 1)
        service.shared.loadKeysIfNeeded()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(requests.values.count == 1)
        service.shared.loadMoreKeys()
        #expect(await eventually { !service.shared.keyList.isLoading && !service.shared.keyList.hasMore })
        #expect(requests.values.count == 2)
        #expect(service.shared.keyList.keys.count == 1)
        service.stop()
    }

    @Test func `auth rejection pauses new automatic private scopes until credential changes`() async {
        let requests = OpenRouterRequestLog()
        let store = OpenRouterMemoryKey("fixture")
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                return Self.response("{}", status: 401)
            }, keys: .init(shared: store.adapter))
        service.demand = OpenRouterDemand.shared(balance: .manual, keepsAccountData: true)
        service.start()
        #expect(
            await eventually { service.shared.balance.problem == .invalidKey && !service.shared.balance.isFetching })
        let attempts = requests.values.count
        service.demand = OpenRouterDemand.shared(
            balance: .manual, activity: [.account: .minutes(15)], keepsAccountData: true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(requests.values.count == attempts)
        service.stop()
    }

    @Test func `queued save remove save preserves the latest credential`() async {
        let replies = Answers<Bool>()
        let store = OpenRouterMemoryKey()
        let events = OpenRouterWriteLog()
        let adapter = OpenRouterKeyStore(
            read: store.adapter.read,
            save: { key in
                let allowed = await replies.next()
                events.append("save:" + key)
                guard allowed else { return false }
                return await store.adapter.save(key)
            },
            delete: {
                events.append("delete")
                return await store.adapter.delete()
            })
        let service = OpenRouterService(
            transport: { _ in
                Self.response(#"{"data":{"is_management_key":true}}"#)
            }, keys: .init(shared: adapter))
        let first = Task { await service.shared.saveKey("first") }
        #expect(await eventually { replies.pendingCount == 1 })
        service.shared.removeKey()
        let last = Task { await service.shared.saveKey("last") }
        await replies.answer(true)
        #expect(await eventually { replies.pendingCount == 1 && events.values == ["save:first", "delete"] })
        await replies.answer(true)
        _ = await first.value
        _ = await last.value
        #expect(events.values == ["save:first", "delete", "save:last"])
        #expect(store.key == "last" && service.shared.hasKey == true)
        service.stop()
    }

    nonisolated private static func response(_ json: String, status: Int = 200) -> HTTP.Response {
        HTTP.Response(status: status, body: Data(json.utf8))
    }
}

private nonisolated final class OpenRouterRequestLog: Sendable {
    private let storage = Mutex<[URLRequest]>([])
    func append(_ request: URLRequest) { storage.withLock { $0.append(request) } }
    var values: [URLRequest] { storage.withLock { $0 } }
}

private nonisolated final class OpenRouterMemoryKey: Sendable {
    private struct State {
        var key: String?
        var reads = 0
        var saves = 0
    }
    private let state: Mutex<State>
    init(_ key: String? = nil) { state = Mutex(State(key: key)) }
    var key: String? { state.withLock { $0.key } }
    var reads: Int { state.withLock { $0.reads } }
    var saves: Int { state.withLock { $0.saves } }
    var adapter: OpenRouterKeyStore {
        OpenRouterKeyStore(
            read: {
                self.state.withLock {
                    $0.reads += 1
                    return $0.key
                }
            },
            save: { key in
                self.state.withLock {
                    $0.saves += 1
                    $0.key = key
                }
                return true
            },
            delete: {
                self.state.withLock { $0.key = nil }
                return true
            })
    }
}

private nonisolated final class OpenRouterWriteLog: Sendable {
    private let storage = Mutex<[String]>([])
    func append(_ event: String) { storage.withLock { $0.append(event) } }
    var values: [String] { storage.withLock { $0 } }
}

extension OpenRouterServiceTests {
    @Test(arguments: [401, 403])
    func `rejected connection gates key pages new scopes and manual refresh until resave`(status: Int) async {
        let requests = OpenRouterRequestLog()
        let store = OpenRouterMemoryKey("fixture")
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                if request.url?.lastPathComponent == "key" {
                    return Self.response(#"{"data":{"is_management_key":true}}"#)
                }
                return Self.response("{}", status: status)
            }, keys: .init(shared: store.adapter))
        service.demand = OpenRouterDemand.shared(balance: .manual, keepsAccountData: true)
        service.start()
        let problem: OpenRouterProblem = status == 401 ? .invalidKey : .notPermitted
        #expect(await eventually { service.shared.balance.problem == problem && !service.shared.balance.isFetching })
        let count = requests.values.count
        service.shared.loadKeysIfNeeded()
        service.shared.refreshAccount(scope: nil)
        service.demand = OpenRouterDemand.shared(
            balance: .manual, activity: [.account: .manual], keepsAccountData: true)
        #expect(await eventually { service.shared.activity(for: .account)?.problem == problem })
        #expect(service.shared.keyList.problem == problem)
        #expect(requests.values.count == count)
        #expect(await service.shared.saveKey("fixture") == nil)
        #expect(await eventually { requests.values.count >= count + 2 })
        #expect(store.saves == 1)
        service.stop()
    }

    @Test(arguments: ["credits", "keys"])
    func `RetryAfter from any private resource gates all newly requested private scopes`(source: String) async {
        let requests = OpenRouterRequestLog()
        let store = OpenRouterMemoryKey("fixture")
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                return HTTP.Response(status: 429, headers: ["rEtRy-AfTeR": "600"], body: Data("{}".utf8))
            }, keys: .init(shared: store.adapter))
        service.demand = OpenRouterDemand.shared(keepsAccountData: true)
        service.start()
        if source == "credits" {
            service.demand = OpenRouterDemand.shared(balance: .manual, keepsAccountData: true)
            #expect(
                await eventually {
                    service.shared.balance.problem == .rateLimited && !service.shared.balance.isFetching
                })
        } else {
            service.shared.loadKeysIfNeeded()
            #expect(
                await eventually { service.shared.keyList.problem == .rateLimited && !service.shared.keyList.isLoading }
            )
        }
        let count = requests.values.count
        service.shared.loadMoreKeys()
        service.shared.loadKeysIfNeeded()
        service.demand = OpenRouterDemand.shared(
            balance: .manual, activity: [.account: .manual, .key(String(repeating: "a", count: 64)): .manual],
            keepsAccountData: true)
        #expect(await eventually { service.shared.activity(for: .account)?.problem == .rateLimited })
        service.shared.refreshAccount(scope: .account)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(requests.values.count == count)
        service.stop()
    }

    @Test func `failed deletion reports truth and retry clears the remaining credential`() async {
        let store = OpenRouterMemoryKey("fixture")
        let deletions = OpenRouterWriteLog()
        let adapter = OpenRouterKeyStore(
            read: store.adapter.read, save: store.adapter.save,
            delete: {
                deletions.append("delete")
                if deletions.values.count == 1 { return false }
                return await store.adapter.delete()
            })
        let service = OpenRouterService(transport: { _ in Self.response("{}") }, keys: .init(shared: adapter))
        service.shared.lookForKey()
        #expect(await eventually { service.shared.hasKey == true })
        service.shared.removeKey()
        #expect(service.shared.hasKey == false)
        #expect(await eventually { service.shared.keyRemovalFailed && service.shared.hasKey == true })
        #expect(store.key == "fixture")
        service.shared.removeKey()
        #expect(
            await eventually { store.key == nil && service.shared.hasKey == false && !service.shared.keyRemovalFailed })
        service.stop()
    }

    @Test func `late failed deletion cannot overwrite a newer credential save`() async {
        let store = OpenRouterMemoryKey("old")
        let deletion = Answers<Bool>()
        let adapter = OpenRouterKeyStore(
            read: store.adapter.read, save: store.adapter.save, delete: { await deletion.next() })
        let service = OpenRouterService(
            transport: { _ in Self.response(#"{"data":{"is_management_key":true}}"#) }, keys: .init(shared: adapter))
        service.shared.removeKey()
        #expect(await eventually { deletion.pendingCount == 1 })
        let save = Task { await service.shared.saveKey("new") }
        await deletion.answer(false)
        #expect(await save.value == nil)
        #expect(store.key == "new" && service.shared.hasKey == true && !service.shared.keyRemovalFailed)
        service.stop()
    }

    @Test func `queued validation overtaken before its write never reaches credential store`() async {
        let store = OpenRouterMemoryKey()
        let writes = Answers<Bool>()
        let events = OpenRouterWriteLog()
        let adapter = OpenRouterKeyStore(
            read: store.adapter.read,
            save: { key in
                events.append(key)
                let allowed = await writes.next()
                guard allowed else { return false }
                return await store.adapter.save(key)
            }, delete: store.adapter.delete)
        let validations = OpenRouterRequestLog()
        let service = OpenRouterService(
            transport: { request in
                validations.append(request)
                return Self.response(#"{"data":{"is_management_key":true}}"#)
            }, keys: .init(shared: adapter))
        let first = Task { await service.shared.saveKey("first") }
        #expect(await eventually { writes.pendingCount == 1 })
        let middle = Task { await service.shared.saveKey("middle") }
        #expect(await eventually { validations.values.count == 2 })
        let last = Task { await service.shared.saveKey("last") }
        #expect(await eventually { validations.values.count == 3 })
        await writes.answer(true)
        #expect(await eventually { writes.pendingCount == 1 })
        #expect(events.values == ["first", "last"])
        await writes.answer(true)
        _ = await first.value
        _ = await middle.value
        _ = await last.value
        #expect(store.key == "last")
        service.stop()
    }

    @Test func `cancellation while a validated save waits in the write queue prevents the write`() async {
        let store = OpenRouterMemoryKey()
        let firstWrite = Answers<Bool>()
        let events = OpenRouterWriteLog()
        let validations = OpenRouterRequestLog()
        let adapter = OpenRouterKeyStore(
            read: store.adapter.read,
            save: { key in
                events.append(key)
                if key == "first" { _ = await firstWrite.next() }
                return await store.adapter.save(key)
            }, delete: store.adapter.delete)
        let service = OpenRouterService(
            transport: { request in
                validations.append(request)
                return Self.response(#"{"data":{"is_management_key":true}}"#)
            }, keys: .init(shared: adapter))
        let first = Task { await service.shared.saveKey("first") }
        #expect(await eventually { firstWrite.pendingCount == 1 })
        let cancelled = Task { await service.shared.saveKey("cancelled") }
        #expect(await eventually { validations.values.count == 2 })
        // Let the validated candidate enter the serialized queue before cancellation.
        try? await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        await firstWrite.answer(true)
        _ = await first.value
        _ = await cancelled.value
        #expect(events.values == ["first"])
        #expect(store.key == "first")
        service.stop()
    }

    @Test func `raw page offsets advance through unreadable rows dedupe across pages and expose limit`() async {
        let requests = OpenRouterRequestLog()
        let hash = String(repeating: "b", count: 64)
        let row = "{\"hash\":\"\(hash)\"}"
        let page = "{\"data\":[null," + Array(repeating: row, count: 99).joined(separator: ",") + "]}"
        let store = OpenRouterMemoryKey("fixture")
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                return Self.response(page)
            }, keys: .init(shared: store.adapter), manualActionGap: .zero)
        service.shared.loadKeysIfNeeded()
        #expect(await eventually { service.shared.keyList.fetchedAt != nil && !service.shared.keyList.isLoading })
        for index in 1..<OpenRouterService.maximumKeyPages {
            service.shared.loadMoreKeys()
            #expect(await eventually { !service.shared.keyList.isLoading && requests.values.count == index + 1 })
        }
        #expect(service.shared.keyList.keys.count == 1)
        #expect(
            service.shared.keyList.nextOffset == 2000 && service.shared.keyList.reachedLimit
                && !service.shared.keyList.hasMore)
        #expect(requests.values[1].url?.query?.contains("offset=100") == true)
        service.shared.loadMoreKeys()
        #expect(requests.values.count == 20)
        service.stop()
    }
}

extension OpenRouterServiceTests {
    @Test func `response crossing UTC midnight anchors activity and resource to the same answer time`() async {
        let before = Date(iso8601: "2026-10-12T23:59:59Z")!
        let after = Date(iso8601: "2026-10-13T00:00:01Z")!
        let wall = Mutex(before)
        let replies = Answers<HTTP.Response>()
        let store = OpenRouterMemoryKey("fixture")
        let service = OpenRouterService(
            transport: { _ in await replies.next() }, keys: .init(shared: store.adapter),
            now: { wall.withLock { $0 } })
        service.demand = OpenRouterDemand.shared(activity: [.account: .manual], keepsAccountData: true)
        service.start()
        #expect(await eventually { replies.pendingCount == 1 })
        wall.withLock { $0 = after }
        await replies.answer(Self.response(#"{"data":[{"date":"2026-10-12","usage":".125"}]}"#))
        #expect(await eventually { service.shared.activity(for: .account)?.value != nil })
        let resource = service.shared.activity(for: .account)
        #expect(resource?.fetchedAt == after && resource?.value?.fetchedAt == after)
        #expect(resource?.value?.lastCompletedDay.description == "2026-10-12")
        #expect(resource?.value?.days(7).last?.usage == Decimal(string: ".125"))
        service.stop()
    }

    @Test func `scoped key lookup rejection gates the activity request and later key pages`() async {
        let requests = OpenRouterRequestLog()
        let store = OpenRouterMemoryKey("fixture")
        let scope = OpenRouterSpendScope.key(String(repeating: "a", count: 64))
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                return Self.response("{}", status: 403)
            }, keys: .init(shared: store.adapter))
        service.demand = OpenRouterDemand.shared(activity: [scope: .manual], keepsAccountData: true)
        service.start()
        #expect(await eventually { service.shared.activity(for: scope)?.problem == .notPermitted })
        service.shared.loadKeysIfNeeded()
        #expect(service.shared.keyList.problem == .notPermitted)
        #expect(requests.values.count == 1)
        #expect(!requests.values.contains { $0.url?.lastPathComponent == "activity" })
        service.stop()
    }
}

extension OpenRouterDemand {
    /// What the shared key's account needs, the way one Balance block reading it asks.
    static func shared(
        balance: RefreshCadence? = nil, activity: [OpenRouterSpendScope: RefreshCadence] = [:],
        keepsAccountData: Bool = false
    ) -> OpenRouterDemand {
        OpenRouterDemand(
            accounts: [.shared: OpenRouterAccountDemand(balance: balance, activity: activity)],
            keptAccounts: keepsAccountData ? [.shared] : [])
    }
}

extension OpenRouterServiceTests {
    @Test func `each account reads with its own key and a block that goes takes only its own key`() async {
        let own = OpenRouterAccountID.own(widget: UUID(), block: UUID())
        let keys = OpenRouterMemoryKeyring([.shared: "shared-key", own: "own-key"])
        let requests = OpenRouterRequestLog()
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                return Self.response(#"{"data":{"total_credits":10,"total_usage":1}}"#)
            }, keys: keys.keyring)
        service.demand = OpenRouterDemand(
            accounts: [.shared: .init(balance: .manual), own: .init(balance: .manual)], keptAccounts: [.shared, own])
        service.start()
        #expect(await eventually { service.shared.balance.value != nil && service.account(own)?.balance.value != nil })
        let authorizations = Set(requests.values.compactMap { $0.value(forHTTPHeaderField: "Authorization") })
        #expect(authorizations == ["Bearer shared-key", "Bearer own-key"])
        // The block went back to the shared key, or was removed: its own key goes, the shared one stays.
        service.demand = OpenRouterDemand(accounts: [.shared: .init(balance: .manual)], keptAccounts: [.shared])
        #expect(service.account(own) == nil)
        #expect(await eventually { keys.key(for: own).key == nil })
        #expect(keys.key(for: .shared).key == "shared-key" && service.shared.balance.value != nil)
        service.stop()
    }

    @Test func `an added own key is saved before the block uses it and outlasts the configuration catching up`() async {
        let own = OpenRouterAccountID.own(widget: UUID(), block: UUID())
        let keys = OpenRouterMemoryKeyring()
        let service = OpenRouterService(
            transport: { _ in Self.response(#"{"data":{"is_management_key":true}}"#) }, keys: keys.keyring)
        service.demand = OpenRouterDemand(keptAccounts: [.shared])
        #expect(await service.addOwnKey("own-key", for: own) == nil)
        #expect(keys.key(for: own).key == "own-key" && service.account(own)?.canUseKey == true)
        // Another change arrives before the configuration says the block uses its own key: the key stays.
        service.demand = OpenRouterDemand(catalogue: .manual, keptAccounts: [.shared])
        #expect(keys.key(for: own).key == "own-key")
        service.demand = OpenRouterDemand(keptAccounts: [.shared, own])
        // Removed: the block reads the shared key again.
        service.demand = OpenRouterDemand(keptAccounts: [.shared])
        #expect(service.account(own) == nil)
        #expect(await eventually { keys.key(for: own).key == nil })
    }

    @Test func `an own key OpenRouter rejects is never saved`() async {
        let own = OpenRouterAccountID.own(widget: UUID(), block: UUID())
        let keys = OpenRouterMemoryKeyring()
        let service = OpenRouterService(
            transport: { _ in Self.response(#"{"data":{"is_management_key":false}}"#) }, keys: keys.keyring)
        #expect(await service.addOwnKey("inference-key", for: own) == .notManagementKey)
        #expect(keys.key(for: own).key == nil && service.account(own) == nil)
    }

    @Test func `a duplicated widget gets its blocks own keys before it is added`() async {
        var settings = OpenRouterSettings(preset: .credits)
        let block = OpenRouterPreset.balanceID
        let widgetID = UUID()
        settings.setBalanceOptions(.init(account: .migratedOpenRouterKey(widget: widgetID, block: block)), for: block)
        let widget = WidgetInstance(id: widgetID, settings: .openRouter(settings))
        let own = OpenRouterAccountID.own(widget: widget.id, block: block)
        let keys = OpenRouterMemoryKeyring([own: "own-key"])
        let service = OpenRouterService(transport: { _ in throw URLError(.notConnectedToInternet) }, keys: keys.keyring)
        service.demand = OpenRouterDemand(keptAccounts: [own])
        let copy = UUID()
        await service.copyOwnKeys(of: widget, to: copy)
        #expect(keys.key(for: .own(widget: copy, block: block)).key == "own-key")
        #expect(keys.key(for: .shared).key == nil)
    }
}

/// A memory key for every account, made as the service first asks for it.
private nonisolated final class OpenRouterMemoryKeyring: Sendable {
    private let keys: Mutex<[OpenRouterAccountID: OpenRouterMemoryKey]>

    init(_ saved: [OpenRouterAccountID: String] = [:]) {
        keys = Mutex(saved.mapValues { OpenRouterMemoryKey($0) })
    }

    func key(for account: OpenRouterAccountID) -> OpenRouterMemoryKey {
        keys.withLock { keys in
            if let key = keys[account] { return key }
            let key = OpenRouterMemoryKey()
            keys[account] = key
            return key
        }
    }

    var keyring: OpenRouterKeyring {
        OpenRouterKeyring { self.key(for: $0).adapter }
    }
}
