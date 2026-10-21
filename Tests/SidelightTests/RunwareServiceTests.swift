import Foundation
import Testing

@testable import Sidelight
@testable import SidelightCore

/// Every request is intercepted, keys live in memory, and the CLI's config is a file of the test's own.
struct RunwareServiceTests {
    nonisolated static let details = #""organizationName":"Acme","balance":{"amount":10,"currency":"USD"}"#
    nonisolated static let activity = #""usage":{"timeseries":{"data":[]},"model":{"data":[]}}"#

    /// Our task's answer to `request`, with `fields`.
    nonisolated static func reply(to request: URLRequest, _ fields: String, status: Int = 200) -> HTTP.Response {
        HTTP.Response(
            status: status,
            body: Data(#"{"data":[{"taskUUID":"\#(taskUUID(of: request))",\#(fields)}]}"#.utf8))
    }

    nonisolated static func taskUUID(of request: URLRequest) -> String {
        let tasks = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
        return tasks?.first?["taskUUID"] as? String ?? ""
    }

    nonisolated static func operation(of request: URLRequest) -> String {
        let tasks = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
        return tasks?.first?["operation"] as? String ?? tasks?.first?["taskType"] as? String ?? ""
    }

    /// Answers every request as Runware would for a healthy account.
    nonisolated static func healthy(_ request: URLRequest) -> HTTP.Response {
        switch operation(of: request) {
        case "getDetails": reply(to: request, details)
        case "getUsageActivity": reply(to: request, activity)
        default: reply(to: request, #""results":[],"totalResults":0"#)
        }
    }

    private static let noCLI = URL.temporaryDirectory.appending(path: "runware-none-\(UUID().uuidString)/config.yaml")

    private func service(
        _ store: TestAccounts, cliConfig: URL = RunwareServiceTests.noCLI,
        transport: @escaping RunwareService.Transport
    ) -> RunwareService {
        RunwareService(transport: transport, accounts: store.access, manualActionGap: .zero, cliConfigFile: cliConfig)
    }

    @Test func `starting twice makes one request`() async {
        let requests = OpenRouterRequestLog()
        let store = TestAccounts("rw_fixture")
        let service = service(store) { request in
            requests.append(request)
            return Self.healthy(request)
        }
        service.demand = .tested(details: .manual)
        service.start()
        service.start()
        #expect(await eventually { service.tested.details.value != nil })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(requests.values.count == 1)
        #expect(requests.values.first?.value(forHTTPHeaderField: "Authorization") == "Bearer rw_fixture")
        #expect(store.statuses[.tested] == .connected)
        service.stop()
    }

    @Test func `stopping during a fetch publishes nothing`() async {
        let replies = Answers<HTTP.Response>()
        let pending = OpenRouterRequestLog()
        let service = service(TestAccounts("rw_fixture")) { request in
            pending.append(request)
            return await replies.next()
        }
        service.demand = .tested(details: .manual)
        service.start()
        #expect(await eventually { replies.pendingCount == 1 })
        service.stop()
        await replies.answer(Self.reply(to: pending.values[0], Self.details))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(service.tested.details.value == nil && !service.tested.details.isFetching)
    }

    @Test func `a replaced key drops what the old one showed, and its late answer`() async {
        let replies = Answers<HTTP.Response>()
        let log = OpenRouterRequestLog()
        let store = TestAccounts("rw_old")
        let service = service(store) { request in
            log.append(request)
            return await replies.next()
        }
        service.demand = .tested(details: .manual)
        service.start()
        #expect(await eventually { replies.pendingCount == 1 })
        await store.replace("rw_new")
        // The old key's answer arrives after the key changed.
        await replies.answer(Self.reply(to: log.values[0], #""balance":999"#))
        #expect(await eventually { replies.pendingCount == 1 })
        #expect(service.tested.details.value == nil)
        await replies.answer(Self.reply(to: log.values[1], Self.details))
        #expect(await eventually { service.tested.details.value?.balance.amount == 10 })
        #expect(log.values.last?.value(forHTTPHeaderField: "Authorization") == "Bearer rw_new")
        service.stop()
    }

    @Test func `a rejected key stops every request until it's replaced`() async {
        let log = OpenRouterRequestLog()
        let store = TestAccounts("rw_bad")
        let service = service(store) { request in
            log.append(request)
            return HTTP.Response(status: 401, body: Data("{}".utf8))
        }
        service.demand = .tested(details: .manual, activity: .manual)
        service.start()
        #expect(await eventually { service.tested.details.problem == .invalidKey })
        #expect(await eventually { service.tested.activity.problem == .invalidKey })
        let count = log.values.count
        service.tested.refresh(includingActivity: true)
        service.tested.loadDayModels(UTCDay(.now).adding(days: -3))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(log.values.count == count && count <= 2)
        #expect(store.statuses[.tested] == .expired)
        service.stop()
    }

    @Test func `Retry-After from one request holds the others`() async {
        let log = OpenRouterRequestLog()
        let service = service(TestAccounts("rw_fixture")) { request in
            log.append(request)
            if Self.operation(of: request) == "getDetails" {
                return HTTP.Response(status: 429, headers: ["Retry-After": "600"], body: Data("{}".utf8))
            }
            return Self.healthy(request)
        }
        service.demand = .tested(details: .manual)
        service.start()
        #expect(await eventually { service.tested.details.problem == .rateLimited })
        // The activity, asked for now, waits as well.
        service.demand = .tested(details: .manual, activity: .manual)
        #expect(await eventually { service.tested.activity.problem == .rateLimited })
        #expect(log.values.count == 1)
        service.stop()
    }

    @Test func `the activity is never fetched more often than every 15 minutes`() {
        #expect(RefreshPolicy(activityAt: .minutes(5)) == .every(.seconds(15 * 60)))
        #expect(RefreshPolicy(activityAt: .minutes(30)) == .every(.seconds(30 * 60)))
        #expect(RefreshPolicy(activityAt: .manual) == .manual)
    }

    @Test func `a completed day's models are fetched once`() async {
        let log = OpenRouterRequestLog()
        let service = service(TestAccounts("rw_fixture")) { request in
            log.append(request)
            return Self.reply(
                to: request, #""usage":{"model":{"data":[{"model":"runware:101@1","count":3,"spend":1}]}}"#)
        }
        service.demand = .tested()
        let day = UTCDay(.now).adding(days: -2)
        service.tested.loadDayModels(day)
        #expect(await eventually { if case .loaded = service.tested.dayModels[day] { true } else { false } })
        service.tested.loadDayModels(day)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(log.values.count == 1)
        if case .loaded(let loaded) = service.tested.dayModels[day] {
            #expect(loaded.models.map(\.air) == ["runware:101@1"])
        }
    }

    @Test func `a search answered with the old key is dropped`() async {
        let replies = Answers<HTTP.Response>()
        let log = OpenRouterRequestLog()
        let store = TestAccounts("rw_old")
        let service = service(store) { request in
            log.append(request)
            return await replies.next()
        }
        service.demand = .tested()
        let account = service.tested
        let search = Task { await account.searchModels(RunwareModelQuery(search: "flux")) }
        #expect(await eventually { replies.pendingCount == 1 })
        await store.replace("rw_new")
        await replies.answer(Self.reply(to: log.values[0], #""results":[{"air":"private:1@1"}]"#))
        #expect(await search.value == nil)
    }

    @Test func `the CLI's key is read from its config, and another key starts over`() async throws {
        let folder = URL.temporaryDirectory.appending(path: "runware-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "config.yaml")
        try Data("api_key: rw_first\n".utf8).write(to: file)
        let log = OpenRouterRequestLog()
        let service = service(TestAccounts(), cliConfig: file) { request in
            log.append(request)
            let key = request.value(forHTTPHeaderField: "Authorization") ?? ""
            return Self.reply(
                to: request, #""organizationName":"\#(key.hasSuffix("first") ? "First" : "Second")","balance":1"#)
        }
        service.demand = RunwareDemand(
            accounts: [.runwareCLI: RunwareAccountDemand(details: .manual)], keptAccounts: [.runwareCLI])
        service.start()
        let cli = try #require(service.account(.runwareCLI))
        #expect(await eventually { cli.details.value?.organizationName == "First" })
        #expect(await eventually { service.cliIsSignedIn })
        try Data("api_key: 'rw_second'\n".utf8).write(to: file)
        service.refreshNow()
        #expect(await eventually { cli.details.value?.organizationName == "Second" })
        #expect(log.values.last?.value(forHTTPHeaderField: "Authorization") == "Bearer rw_second")
        try FileManager.default.removeItem(at: file)
        service.refreshNow()
        #expect(await eventually { service.cliStatus == .signedOut })
        #expect(await eventually { cli.details.problem == .cliNotSignedIn })
        #expect(cli.details.value == nil)
        service.stop()
    }

    @Test func `signing in with the CLI is noticed before its folder exists`() async throws {
        let home = URL.temporaryDirectory.appending(path: "runware-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appending(path: ".runware", directoryHint: .isDirectory)
        let service = service(TestAccounts(), cliConfig: folder.appending(path: "config.yaml")) { Self.healthy($0) }
        service.demand = RunwareDemand(
            accounts: [.runwareCLI: RunwareAccountDemand(details: .manual)], keptAccounts: [.runwareCLI])
        service.start()
        #expect(await eventually { service.cliStatus == .signedOut })
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("api_key: rw_later\n".utf8).write(to: folder.appending(path: "config.yaml"))
        #expect(await eventually { service.cliIsSignedIn })
        #expect(await eventually { service.account(.runwareCLI)?.details.value?.organizationName == "Acme" })
        service.stop()
    }

    @Test func `the organization is reported as the account's identity`() async {
        let identities = IdentityLog()
        let keyring = TestAccounts("rw_fixture").keyring
        let access = AccountAccess(
            secret: { id throws(KeychainUnavailable) in try await keyring.secret(for: id) },
            reportIdentity: { identity, _ in identities.values.append(identity) })
        let service = RunwareService(
            transport: { Self.healthy($0) }, accounts: access, cliConfigFile: Self.noCLI)
        service.demand = .tested(details: .manual)
        service.start()
        #expect(await eventually { identities.values.contains("Acme") })
        service.stop()
    }

    @Test func `a key is checked with one details request`() async {
        let log = OpenRouterRequestLog()
        let service = service(TestAccounts()) { request in
            log.append(request)
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer rw_good"
                ? Self.healthy(request) : HTTP.Response(status: 401, body: Data())
        }
        #expect(await service.checkKey(" rw_good ") == nil)
        #expect(await service.checkKey("rw_bad") == .invalidKey)
        #expect(await service.checkKey("  ") == .noKey)
        #expect(log.values.count == 2)
    }
}

private final class IdentityLog {
    var values: [String?] = []
}

extension RunwareDemand {
    /// What the tested account needs, kept.
    static func tested(details: RefreshCadence? = nil, activity: RefreshCadence? = nil) -> RunwareDemand {
        RunwareDemand(
            accounts: [.tested: RunwareAccountDemand(details: details, activity: activity)], keptAccounts: [.tested])
    }
}

extension RunwareService {
    var tested: RunwareAccount { account(.tested)! }
}
