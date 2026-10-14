import Foundation
import Synchronization
import Testing

@testable import Sidelight
@testable import SidelightCore

/// Every request is intercepted and every credential operation uses memory only.
struct OpenRouterServiceTests {
    @Test func `public demand coalesces and never reads credential store`() async throws {
        let requests = OpenRouterRequestLog()
        let store = TestAccounts()
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                return Self.response(#"{"data":[{"id":"fixture/model"}]}"#)
            }, accounts: store.access)
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
        #expect(store.reads == 0 && service.account(.tested) == nil)
        service.stop()
    }

    @Test func `balance and chart share one credential read and stopping suppresses late answers`() async throws {
        let replies = Answers<HTTP.Response>()
        let store = TestAccounts("fixture")
        let requests = OpenRouterRequestLog()
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                return await replies.next()
            }, accounts: store.access)
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
        #expect(service.tested.balance.value == nil)
        #expect(service.tested.activity(for: .account)?.value == nil)
        #expect(!service.tested.balance.isFetching)
    }

    @Test func `credential removal clears cache and prevents old account answer`() async throws {
        let replies = Answers<HTTP.Response>()
        let store = TestAccounts("old-fixture")
        let service = OpenRouterService(transport: { _ in await replies.next() }, accounts: store.access)
        service.demand = OpenRouterDemand.shared(balance: .manual, keepsAccountData: true)
        service.start()
        #expect(await eventually { replies.pendingCount == 1 })
        await store.remove()
        await replies.answer(Self.response(#"{"data":{"total_credits":999,"total_usage":1}}"#))
        #expect(await eventually { service.tested.balance.problem == .noKey && !service.tested.balance.isFetching })
        #expect(service.tested.balance.value == nil && service.tested.hasKey == false)
        #expect(store.statuses[.tested] == .needsSignIn)
        service.stop()
    }

    @Test func `an inference key is turned down before it's added`() async throws {
        let service = OpenRouterService(
            transport: { _ in Self.response(#"{"data":{"is_management_key":false}}"#) },
            accounts: TestAccounts().access)
        #expect(await service.checkKey("fixture") == .notManagementKey)
        #expect(await service.checkKey("  ") == .noKey)
    }

    @Test func `a key OpenRouter doesn't say about is checked by reading the credits`() async throws {
        let service = OpenRouterService(
            transport: { request in
                request.url?.lastPathComponent == "credits"
                    ? Self.response("{}", status: 403) : Self.response(#"{"data":{"label":"x"}}"#)
            }, accounts: TestAccounts().access)
        #expect(await service.checkKey("fixture") == .notManagementKey)
    }

    @Test func `key scoped activity never falls back when selected key disappeared`() async throws {
        let requests = OpenRouterRequestLog()
        let store = TestAccounts("fixture")
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                return Self.response("{}", status: 404)
            }, accounts: store.access)
        let scope = OpenRouterSpendScope.key(String(repeating: "a", count: 64))
        service.demand = OpenRouterDemand.shared(activity: [scope: .manual], keepsAccountData: true)
        service.start()
        #expect(await eventually { service.tested.activity(for: scope)?.problem == .keyNotFound })
        #expect(requests.values.count == 1)
        #expect(!requests.values.contains { $0.url?.lastPathComponent == "activity" })
        #expect(service.tested.activity(for: scope)?.value == nil)
        service.stop()
    }

    @Test func `key picker deduplicates within a page and loads additional pages explicitly`() async throws {
        let hash = String(repeating: "a", count: 64)
        let row = "{\"hash\":\"\(hash)\",\"name\":\"Fixture\"}"
        let json = "{\"data\":[" + Array(repeating: row, count: 100).joined(separator: ",") + "]}"
        let requests = OpenRouterRequestLog()
        let store = TestAccounts("fixture")
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                if request.url?.query?.contains("offset=100") == true { return Self.response(#"{"data":[]}"#) }
                return Self.response(json)
            }, accounts: store.access)
        service.demand = OpenRouterDemand.shared(keepsAccountData: true)
        service.tested.loadKeysIfNeeded()
        #expect(await eventually { service.tested.keyList.fetchedAt != nil && !service.tested.keyList.isLoading })
        #expect(service.tested.keyList.keys.count == 1)
        #expect(service.tested.keyList.hasMore)
        #expect(requests.values.count == 1)
        service.tested.loadKeysIfNeeded()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(requests.values.count == 1)
        service.tested.loadMoreKeys()
        #expect(await eventually { !service.tested.keyList.isLoading && !service.tested.keyList.hasMore })
        #expect(requests.values.count == 2)
        #expect(service.tested.keyList.keys.count == 1)
        service.stop()
    }

    @Test func `auth rejection pauses new automatic private scopes until credential changes`() async throws {
        let requests = OpenRouterRequestLog()
        let store = TestAccounts("fixture")
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                return Self.response("{}", status: 401)
            }, accounts: store.access)
        service.demand = OpenRouterDemand.shared(balance: .manual, keepsAccountData: true)
        service.start()
        #expect(
            await eventually { service.tested.balance.problem == .invalidKey && !service.tested.balance.isFetching })
        let attempts = requests.values.count
        service.demand = OpenRouterDemand.shared(
            balance: .manual, activity: [.account: .minutes(15)], keepsAccountData: true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(requests.values.count == attempts)
        service.stop()
    }

    nonisolated private static func response(_ json: String, status: Int = 200) -> HTTP.Response {
        HTTP.Response(status: status, body: Data(json.utf8))
    }
}

nonisolated final class OpenRouterRequestLog: Sendable {
    private let storage = Mutex<[URLRequest]>([])
    func append(_ request: URLRequest) { storage.withLock { $0.append(request) } }
    var values: [URLRequest] { storage.withLock { $0 } }
}

extension OpenRouterServiceTests {
    @Test(arguments: [401, 403])
    func `rejected connection gates key pages new scopes and manual refresh until resave`(status: Int) async {
        let requests = OpenRouterRequestLog()
        let store = TestAccounts("fixture")
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                if request.url?.lastPathComponent == "key" {
                    return Self.response(#"{"data":{"is_management_key":true}}"#)
                }
                return Self.response("{}", status: status)
            }, accounts: store.access)
        service.demand = OpenRouterDemand.shared(balance: .manual, keepsAccountData: true)
        service.start()
        let problem: OpenRouterProblem = status == 401 ? .invalidKey : .notPermitted
        #expect(await eventually { service.tested.balance.problem == problem && !service.tested.balance.isFetching })
        let count = requests.values.count
        service.tested.loadKeysIfNeeded()
        service.tested.refreshAccount(scope: nil)
        service.demand = OpenRouterDemand.shared(
            balance: .manual, activity: [.account: .manual], keepsAccountData: true)
        #expect(await eventually { service.tested.activity(for: .account)?.problem == problem })
        #expect(service.tested.keyList.problem == problem)
        #expect(requests.values.count == count)
        #expect(store.statuses[.tested] == (status == 401 ? .expired : .failed(problem.title)))
        await store.replace("fixture")
        #expect(await eventually { requests.values.count >= count + 2 })
        service.stop()
    }

    @Test(arguments: ["credits", "keys"])
    func `RetryAfter from any private resource gates all newly requested private scopes`(source: String) async {
        let requests = OpenRouterRequestLog()
        let store = TestAccounts("fixture")
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                return HTTP.Response(status: 429, headers: ["rEtRy-AfTeR": "600"], body: Data("{}".utf8))
            }, accounts: store.access)
        service.demand = OpenRouterDemand.shared(keepsAccountData: true)
        service.start()
        if source == "credits" {
            service.demand = OpenRouterDemand.shared(balance: .manual, keepsAccountData: true)
            #expect(
                await eventually {
                    service.tested.balance.problem == .rateLimited && !service.tested.balance.isFetching
                })
        } else {
            service.tested.loadKeysIfNeeded()
            #expect(
                await eventually { service.tested.keyList.problem == .rateLimited && !service.tested.keyList.isLoading }
            )
        }
        let count = requests.values.count
        service.tested.loadMoreKeys()
        service.tested.loadKeysIfNeeded()
        service.demand = OpenRouterDemand.shared(
            balance: .manual, activity: [.account: .manual, .key(String(repeating: "a", count: 64)): .manual],
            keepsAccountData: true)
        #expect(await eventually { service.tested.activity(for: .account)?.problem == .rateLimited })
        service.tested.refreshAccount(scope: .account)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(requests.values.count == count)
        service.stop()
    }

    @Test func `raw page offsets advance through unreadable rows dedupe across pages and expose limit`() async throws {
        let requests = OpenRouterRequestLog()
        let hash = String(repeating: "b", count: 64)
        let row = "{\"hash\":\"\(hash)\"}"
        let page = "{\"data\":[null," + Array(repeating: row, count: 99).joined(separator: ",") + "]}"
        let store = TestAccounts("fixture")
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                return Self.response(page)
            }, accounts: store.access, manualActionGap: .zero)
        service.demand = OpenRouterDemand.shared(keepsAccountData: true)
        service.tested.loadKeysIfNeeded()
        #expect(await eventually { service.tested.keyList.fetchedAt != nil && !service.tested.keyList.isLoading })
        for index in 1..<OpenRouterService.maximumKeyPages {
            service.tested.loadMoreKeys()
            #expect(await eventually { !service.tested.keyList.isLoading && requests.values.count == index + 1 })
        }
        #expect(service.tested.keyList.keys.count == 1)
        #expect(
            service.tested.keyList.nextOffset == 2000 && service.tested.keyList.reachedLimit
                && !service.tested.keyList.hasMore)
        #expect(requests.values[1].url?.query?.contains("offset=100") == true)
        service.tested.loadMoreKeys()
        #expect(requests.values.count == 20)
        service.stop()
    }
}

extension OpenRouterServiceTests {
    @Test func `response crossing UTC midnight anchors activity and resource to the same answer time`() async throws {
        let before = Date(iso8601: "2026-10-12T23:59:59Z")!
        let after = Date(iso8601: "2026-10-13T00:00:01Z")!
        let wall = Mutex(before)
        let replies = Answers<HTTP.Response>()
        let store = TestAccounts("fixture")
        let service = OpenRouterService(
            transport: { _ in await replies.next() }, accounts: store.access,
            now: { wall.withLock { $0 } })
        service.demand = OpenRouterDemand.shared(activity: [.account: .manual], keepsAccountData: true)
        service.start()
        #expect(await eventually { replies.pendingCount == 1 })
        wall.withLock { $0 = after }
        await replies.answer(Self.response(#"{"data":[{"date":"2026-10-12","usage":".125"}]}"#))
        #expect(await eventually { service.tested.activity(for: .account)?.value != nil })
        let resource = service.tested.activity(for: .account)
        #expect(resource?.fetchedAt == after && resource?.value?.fetchedAt == after)
        #expect(resource?.value?.lastCompletedDay.description == "2026-10-12")
        #expect(resource?.value?.days(7).last?.usage == Decimal(string: ".125"))
        service.stop()
    }

    @Test func `scoped key lookup rejection gates the activity request and later key pages`() async throws {
        let requests = OpenRouterRequestLog()
        let store = TestAccounts("fixture")
        let scope = OpenRouterSpendScope.key(String(repeating: "a", count: 64))
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                return Self.response("{}", status: 403)
            }, accounts: store.access)
        service.demand = OpenRouterDemand.shared(activity: [scope: .manual], keepsAccountData: true)
        service.start()
        #expect(await eventually { service.tested.activity(for: scope)?.problem == .notPermitted })
        service.tested.loadKeysIfNeeded()
        #expect(service.tested.keyList.problem == .notPermitted)
        #expect(requests.values.count == 1)
        #expect(!requests.values.contains { $0.url?.lastPathComponent == "activity" })
        service.stop()
    }
}

extension OpenRouterDemand {
    /// What the tested account needs, the way one Balance block reading it asks.
    static func shared(
        balance: RefreshCadence? = nil, activity: [OpenRouterSpendScope: RefreshCadence] = [:],
        keepsAccountData: Bool = false
    ) -> OpenRouterDemand {
        OpenRouterDemand(
            accounts: [.tested: OpenRouterAccountDemand(balance: balance, activity: activity)],
            keptAccounts: keepsAccountData ? [.tested] : [])
    }
}

extension OpenRouterServiceTests {
    @Test func `each account reads with its own key, once for every block on it`() async throws {
        let other = AccountID(rawValue: "other")
        let store = TestAccounts([.tested: "tested-key", other: "other-key"])
        let requests = OpenRouterRequestLog()
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                return Self.response(#"{"data":{"total_credits":10,"total_usage":1}}"#)
            }, accounts: store.access)
        service.demand = OpenRouterDemand(
            accounts: [.tested: .init(balance: .manual), other: .init(balance: .manual)],
            keptAccounts: [.tested, other])
        service.start()
        #expect(
            await eventually { service.tested.balance.value != nil && service.account(other)?.balance.value != nil })
        let authorizations = requests.values.compactMap { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(authorizations.sorted() == ["Bearer other-key", "Bearer tested-key"])
        #expect(store.statuses == [.tested: .connected, other: .connected])
        // No block uses it any more: what it showed goes, its key stays the account's.
        service.demand = OpenRouterDemand(accounts: [.tested: .init(balance: .manual)], keptAccounts: [.tested])
        #expect(service.account(other) == nil)
        #expect(try await store.keyring.secret(for: other) == "other-key")
        #expect(service.tested.balance.value != nil)
        service.stop()
    }
}

extension OpenRouterServiceTests {
    @Test func `a keychain that can't be read isn't a missing key, and is tried again`() async throws {
        let requests = OpenRouterRequestLog()
        let service = OpenRouterService(
            transport: { request in
                requests.append(request)
                return Self.response(#"{"data":{"total_credits":10,"total_usage":1}}"#)
            },
            accounts: AccountAccess(secret: { _ throws(KeychainUnavailable) in throw KeychainUnavailable() }))
        service.demand = OpenRouterDemand.shared(balance: .manual, keepsAccountData: true)
        service.start()
        #expect(await eventually { service.tested.balance.problem == .keychain })
        #expect(OpenRouterProblem.keychain.accountStatus?.needsSignIn == false)
        #expect(OpenRouterAPI.retryAdvice(for: .keychain, now: .now) == .backoff)
        #expect(requests.values.isEmpty)
        service.stop()
    }
}

extension AccountID {
    static let tested = AccountID(rawValue: "tested")
}

extension OpenRouterService {
    /// The tested account, which the test's demand keeps.
    var tested: OpenRouterAccount { account(.tested)! }
}

/// Accounts' keys in memory, through the keyring the services read, with what the services report.
final class TestAccounts {
    let keyring: AccountKeyring
    private(set) var statuses: [AccountID: AccountStatus] = [:]
    private let lookUps = LookUpCount()

    init(_ keys: [AccountID: String] = [:]) {
        var secrets = AccountSecrets.memory(keys)
        let read = secrets.read
        let lookUps = lookUps
        secrets.read = { id throws(KeychainUnavailable) in
            lookUps.count.withLock { $0 += 1 }
            return try await read(id)
        }
        keyring = AccountKeyring(secrets: secrets)
    }

    /// The tested account's key.
    convenience init(_ key: String) {
        self.init([.tested: key])
    }

    /// How many times a key was read from the (stand-in) keychain.
    var reads: Int { lookUps.count.withLock { $0 } }

    var access: AccountAccess {
        let keyring = keyring
        return AccountAccess(
            secret: { id throws(KeychainUnavailable) in try await keyring.secret(for: id) },
            observeChanges: { keyring.observeChanges($0) },
            report: { status, id in self.statuses[id] = status })
    }

    /// Replaces the tested account's key, as Settings would.
    func replace(_ key: String) async {
        _ = await keyring.save(key, for: Account(id: .tested, provider: .openRouter, name: "Tested", kind: .key))
    }

    /// Removes the tested account's key, as removing the account would.
    func remove() async {
        await keyring.delete(.tested)
    }
}

private nonisolated final class LookUpCount: Sendable {
    let count = Mutex(0)
}
