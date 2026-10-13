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
            }, keyStore: store.adapter)
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
        #expect(store.reads == 0 && service.hasKey == nil)
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
            }, keyStore: store.adapter)
        service.demand = OpenRouterDemand(balance: .manual, activity: [.account: .manual], keepsAccountData: true)
        service.start()
        #expect(await eventually { replies.pendingCount == 2 })
        #expect(store.reads == 1)
        #expect(Set(requests.values.compactMap { $0.url?.lastPathComponent }) == ["credits", "activity"])
        service.stop()
        await replies.answer(Self.response(#"{"data":{"total_credits":10,"total_usage":1}}"#))
        await replies.answer(Self.response(#"{"data":[]}"#))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(service.balance.value == nil)
        #expect(service.activity(for: .account)?.value == nil)
        #expect(!service.balance.isFetching)
    }

    @Test func `credential removal clears cache and prevents old account answer`() async {
        let replies = Answers<HTTP.Response>()
        let store = OpenRouterMemoryKey("old-fixture")
        let service = OpenRouterService(transport: { _ in await replies.next() }, keyStore: store.adapter)
        service.demand = OpenRouterDemand(balance: .manual, keepsAccountData: true)
        service.start()
        #expect(await eventually { replies.pendingCount == 1 })
        service.removeKey()
        await replies.answer(Self.response(#"{"data":{"total_credits":999,"total_usage":1}}"#))
        #expect(await eventually { service.balance.problem == .noKey && !service.balance.isFetching })
        #expect(service.balance.value == nil && service.hasKey == false)
        #expect(await eventually { store.key == nil })
        service.stop()
    }

    @Test func `inference key validation never writes credential`() async {
        let store = OpenRouterMemoryKey()
        let service = OpenRouterService(
            transport: { _ in Self.response(#"{"data":{"is_management_key":false}}"#) }, keyStore: store.adapter)
        #expect(await service.saveKey("fixture") == .notManagementKey)
        #expect(store.saves == 0 && store.key == nil)
        service.stop()
    }

    @Test func `cancelled validation never saves a credential`() async {
        let replies = Answers<HTTP.Response>()
        let store = OpenRouterMemoryKey()
        let service = OpenRouterService(transport: { _ in await replies.next() }, keyStore: store.adapter)
        let saving = Task { await service.saveKey("fixture") }
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
        let service = OpenRouterService(transport: { _ in await replies.next() }, keyStore: store.adapter)
        let saving = Task { await service.saveKey("candidate") }
        #expect(await eventually { replies.pendingCount == 1 })
        service.removeKey()
        await replies.answer(Self.response(#"{"data":{"is_management_key":true}}"#))
        _ = await saving.value
        #expect(await eventually { store.key == nil })
        #expect(store.saves == 0 && service.hasKey == false)
        service.stop()
    }

    @Test func `key scoped activity never falls back when selected key disappeared`() async {
        let requests = OpenRouterRequestLog()
        let store = OpenRouterMemoryKey("fixture")
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                return Self.response("{}", status: 404)
            }, keyStore: store.adapter)
        let scope = OpenRouterSpendScope.key(String(repeating: "a", count: 64))
        service.demand = OpenRouterDemand(activity: [scope: .manual], keepsAccountData: true)
        service.start()
        #expect(await eventually { service.activity(for: scope)?.problem == .keyNotFound })
        #expect(requests.values.count == 1)
        #expect(!requests.values.contains { $0.url?.lastPathComponent == "activity" })
        #expect(service.activity(for: scope)?.value == nil)
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
            }, keyStore: store.adapter)
        service.loadKeysIfNeeded()
        #expect(await eventually { service.keyList.fetchedAt != nil && !service.keyList.isLoading })
        #expect(service.keyList.keys.count == 1)
        #expect(service.keyList.hasMore)
        #expect(requests.values.count == 1)
        service.loadKeysIfNeeded()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(requests.values.count == 1)
        service.loadMoreKeys()
        #expect(await eventually { !service.keyList.isLoading && !service.keyList.hasMore })
        #expect(requests.values.count == 2)
        #expect(service.keyList.keys.count == 1)
        service.stop()
    }

    @Test func `auth rejection pauses new automatic private scopes until credential changes`() async {
        let requests = OpenRouterRequestLog()
        let store = OpenRouterMemoryKey("fixture")
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                return Self.response("{}", status: 401)
            }, keyStore: store.adapter)
        service.demand = OpenRouterDemand(balance: .manual, keepsAccountData: true)
        service.start()
        #expect(await eventually { service.balance.problem == .invalidKey && !service.balance.isFetching })
        let attempts = requests.values.count
        service.demand = OpenRouterDemand(balance: .manual, activity: [.account: .minutes(15)], keepsAccountData: true)
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
            }, keyStore: adapter)
        let first = Task { await service.saveKey("first") }
        #expect(await eventually { replies.pendingCount == 1 })
        service.removeKey()
        let last = Task { await service.saveKey("last") }
        await replies.answer(true)
        #expect(await eventually { replies.pendingCount == 1 && events.values == ["save:first", "delete"] })
        await replies.answer(true)
        _ = await first.value
        _ = await last.value
        #expect(events.values == ["save:first", "delete", "save:last"])
        #expect(store.key == "last" && service.hasKey == true)
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
