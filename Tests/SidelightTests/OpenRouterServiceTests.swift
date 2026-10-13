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
            }, keyStore: store.adapter)
        service.demand = OpenRouterDemand(balance: .manual, keepsAccountData: true)
        service.start()
        let problem: OpenRouterProblem = status == 401 ? .invalidKey : .notPermitted
        #expect(await eventually { service.balance.problem == problem && !service.balance.isFetching })
        let count = requests.values.count
        service.loadKeysIfNeeded()
        service.refreshAccount(scope: nil)
        service.demand = OpenRouterDemand(balance: .manual, activity: [.account: .manual], keepsAccountData: true)
        #expect(await eventually { service.activity(for: .account)?.problem == problem })
        #expect(service.keyList.problem == problem)
        #expect(requests.values.count == count)
        #expect(await service.saveKey("fixture") == nil)
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
            }, keyStore: store.adapter)
        service.demand = OpenRouterDemand(keepsAccountData: true)
        service.start()
        if source == "credits" {
            service.demand = OpenRouterDemand(balance: .manual, keepsAccountData: true)
            #expect(await eventually { service.balance.problem == .rateLimited && !service.balance.isFetching })
        } else {
            service.loadKeysIfNeeded()
            #expect(await eventually { service.keyList.problem == .rateLimited && !service.keyList.isLoading })
        }
        let count = requests.values.count
        service.loadMoreKeys()
        service.loadKeysIfNeeded()
        service.demand = OpenRouterDemand(
            balance: .manual, activity: [.account: .manual, .key(String(repeating: "a", count: 64)): .manual],
            keepsAccountData: true)
        #expect(await eventually { service.activity(for: .account)?.problem == .rateLimited })
        service.refreshAccount(scope: .account)
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
        let service = OpenRouterService(transport: { _ in Self.response("{}") }, keyStore: adapter)
        service.lookForKey()
        #expect(await eventually { service.hasKey == true })
        service.removeKey()
        #expect(service.hasKey == false)
        #expect(await eventually { service.keyRemovalFailed && service.hasKey == true })
        #expect(store.key == "fixture")
        service.removeKey()
        #expect(await eventually { store.key == nil && service.hasKey == false && !service.keyRemovalFailed })
        service.stop()
    }

    @Test func `late failed deletion cannot overwrite a newer credential save`() async {
        let store = OpenRouterMemoryKey("old")
        let deletion = Answers<Bool>()
        let adapter = OpenRouterKeyStore(
            read: store.adapter.read, save: store.adapter.save, delete: { await deletion.next() })
        let service = OpenRouterService(
            transport: { _ in Self.response(#"{"data":{"is_management_key":true}}"#) }, keyStore: adapter)
        service.removeKey()
        #expect(await eventually { deletion.pendingCount == 1 })
        let save = Task { await service.saveKey("new") }
        await deletion.answer(false)
        #expect(await save.value == nil)
        #expect(store.key == "new" && service.hasKey == true && !service.keyRemovalFailed)
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
            }, keyStore: adapter)
        let first = Task { await service.saveKey("first") }
        #expect(await eventually { writes.pendingCount == 1 })
        let middle = Task { await service.saveKey("middle") }
        #expect(await eventually { validations.values.count == 2 })
        let last = Task { await service.saveKey("last") }
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
            }, keyStore: adapter)
        let first = Task { await service.saveKey("first") }
        #expect(await eventually { firstWrite.pendingCount == 1 })
        let cancelled = Task { await service.saveKey("cancelled") }
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
            }, keyStore: store.adapter)
        service.loadKeysIfNeeded()
        #expect(await eventually { service.keyList.fetchedAt != nil && !service.keyList.isLoading })
        for index in 1..<OpenRouterService.maximumKeyPages {
            service.loadMoreKeys()
            #expect(await eventually { !service.keyList.isLoading && requests.values.count == index + 1 })
        }
        #expect(service.keyList.keys.count == 1)
        #expect(service.keyList.nextOffset == 2000 && service.keyList.reachedLimit && !service.keyList.hasMore)
        #expect(requests.values[1].url?.query?.contains("offset=100") == true)
        service.loadMoreKeys()
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
            transport: { _ in await replies.next() }, keyStore: store.adapter,
            now: { wall.withLock { $0 } })
        service.demand = OpenRouterDemand(activity: [.account: .manual], keepsAccountData: true)
        service.start()
        #expect(await eventually { replies.pendingCount == 1 })
        wall.withLock { $0 = after }
        await replies.answer(Self.response(#"{"data":[{"date":"2026-10-12","usage":".125"}]}"#))
        #expect(await eventually { service.activity(for: .account)?.value != nil })
        let resource = service.activity(for: .account)
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
            }, keyStore: store.adapter)
        service.demand = OpenRouterDemand(activity: [scope: .manual], keepsAccountData: true)
        service.start()
        #expect(await eventually { service.activity(for: scope)?.problem == .notPermitted })
        service.loadKeysIfNeeded()
        #expect(service.keyList.problem == .notPermitted)
        #expect(requests.values.count == 1)
        #expect(!requests.values.contains { $0.url?.lastPathComponent == "activity" })
        service.stop()
    }
}
