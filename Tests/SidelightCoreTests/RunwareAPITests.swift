import Foundation
import Testing

@testable import SidelightCore

/// Synthetic answers in the shapes Runware documents (`runware.ai/docs/platform/…`); not captures of a real account.
struct RunwareAPITests {
    let now = Date(timeIntervalSince1970: 1_792_540_800)  // 2026-10-21 UTC
    let uuid = UUID(uuidString: "F4DD3DFE-955F-49D5-A785-7E3B633D6E7A")!

    private func response(_ json: String, status: Int = 200, headers: [String: String] = [:]) -> HTTP.Response {
        HTTP.Response(status: status, headers: headers, body: Data(json.utf8))
    }

    /// `{"data": [task]}` for our task, with `fields` added.
    private func answer(_ fields: String, taskUUID: String? = nil) -> HTTP.Response {
        response(
            #"{"data":[{"taskType":"accountManagement","taskUUID":"\#(taskUUID ?? uuid.uuidString.lowercased())"\#(fields.isEmpty ? "" : "," + fields)}]}"#
        )
    }

    private func body(_ request: URLRequest) throws -> [[String: Any]] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    // MARK: Details

    @Test func `details read the documented balance, usage and keys, never the team`() throws {
        let json = """
            "organizationUUID":"a6379343","organizationName":"Acme Corporation",
            "balance":{"amount":2450.75,"freeBalance":120.00,"currency":"usd"},
            "team":[{"name":"John Smith","email":"john@example.com"}],
            "apiKeys":[{"name":"Production","apiKey":"YHlu****","enabled":true,"createdAt":"2024-01-20T11:00:00Z",
              "requests":15420,"lastUsedAt":"2025-10-12T08:45:30Z"},{"name":"Old","enabled":false}],
            "usage":{"today":{"credits":35.80,"requests":1850},"last7Days":{"credits":"412.25","requests":21400},
              "last30Days":{"requests":87560},"total":{"credits":"oops","requests":2540318}}
            """
        let details = try RunwareAPI.details(answer(json), taskUUID: uuid, fetchedAt: now).get()
        #expect(details.organizationName == "Acme Corporation")
        #expect(
            details.balance == RunwareBalance(amount: Decimal(string: "2450.75")!, freeBalance: 120, currency: "USD"))
        #expect(details.usage.today == RunwareUsageTotal(spend: Decimal(string: "35.8")!, requests: 1850))
        #expect(details.usage.last7Days?.spend == Decimal(string: "412.25")!)
        #expect(details.usage.last30Days == RunwareUsageTotal(spend: nil, requests: 87560))
        #expect(details.usage.total == RunwareUsageTotal(spend: nil, requests: 2_540_318))
        #expect(details.apiKeys.map(\.name) == ["Production", "Old"])
        #expect(details.apiKeys[0].lastUsedAt != nil && details.apiKeys[1].lastUsedAt == nil)
        #expect(!details.apiKeys[1].isEnabled)
        #expect(!String(describing: details).contains("john") && !String(describing: details).contains("YHlu"))
        #expect(details.fetchedAt == now)
    }

    @Test func `a bare-number balance is read, in dollars, without free credits`() throws {
        let details = try RunwareAPI.details(answer(#""balance":12.5"#), taskUUID: uuid, fetchedAt: now).get()
        #expect(details.balance == RunwareBalance(amount: Decimal(string: "12.5")!, freeBalance: nil, currency: "USD"))
        #expect(details.usage == RunwareRollingUsage())
        #expect(details.organizationName == nil)
    }

    @Test(arguments: [#""balance":{"freeBalance":3}"#, #""balance":"lots""#, #""usage":{}"#, #""balance":null"#])
    func `a balance that can't be read is a failure, never zero`(fields: String) {
        #expect(RunwareAPI.details(answer(fields), taskUUID: uuid, fetchedAt: now) == .failure(.unreadable))
    }

    // MARK: Envelope

    @Test func `another task's data isn't ours`() {
        let other = answer(#""balance":1"#, taskUUID: UUID().uuidString)
        #expect(RunwareAPI.details(other, taskUUID: uuid, fetchedAt: now) == .failure(.unreadable))
    }

    @Test func `an error for our task in a 200 is its problem, while another task's error isn't`() {
        let ours = response(
            #"{"errors":[{"code":"invalidApiKey","message":"Bad key","taskUUID":"\#(uuid.uuidString)"}]}"#)
        #expect(RunwareAPI.details(ours, taskUUID: uuid, fetchedAt: now) == .failure(.invalidKey))
        let mixed = response(
            #"{"data":[{"taskUUID":"\#(uuid.uuidString)","balance":5}],"#
                + #""errors":[{"code":"timeoutProvider","message":"x","taskUUID":"\#(UUID().uuidString)"}]}"#)
        #expect((try? RunwareAPI.details(mixed, taskUUID: uuid, fetchedAt: now).get())?.balance.amount == 5)
    }

    @Test func `statuses say what went wrong before the body does`() {
        func problem(_ status: Int, _ json: String = "{}") -> RunwareProblem? {
            if case .failure(let problem) = RunwareAPI.details(
                response(json, status: status), taskUUID: uuid, fetchedAt: now)
            {
                return problem
            }
            return nil
        }
        #expect(problem(401) == .invalidKey)
        #expect(problem(403) == .notPermitted)
        #expect(problem(429) == .rateLimited)
        #expect(problem(503) == .unavailable(status: 503))
        #expect(problem(302) == .unreadable)
        #expect(problem(400) == .badRequest(code: nil, message: nil))
        let long = String(repeating: "x", count: 500)
        let rejected = problem(400, #"{"errors":[{"code":"invalidStartDate","message":"\#(long)"}]}"#)
        #expect(rejected == .badRequest(code: "invalidStartDate", message: String(repeating: "x", count: 200)))
        let large = HTTP.Response(status: 200, body: Data(count: RunwareAPI.sizeLimit + 1))
        #expect(RunwareAPI.details(large, taskUUID: uuid, fetchedAt: now) == .failure(.tooLarge))
    }

    @Test func `retry follows retryAfter in the answer, then the header, then backs off`() {
        let body = response(#"{"errors":[{"code":"rateLimitExceeded","message":"x","retryAfter":30}]}"#, status: 429)
        #expect(
            RunwareAPI.retryAdvice(for: .rateLimited, response: body, now: now)
                == .notBefore(now.addingTimeInterval(30)))
        let header = response("{}", status: 429, headers: ["retry-after": "120"])
        #expect(
            RunwareAPI.retryAdvice(for: .rateLimited, response: header, now: now)
                == .notBefore(now.addingTimeInterval(120)))
        #expect(RunwareAPI.retryAdvice(for: .unavailable(status: 500), response: response("{}"), now: now) == .backoff)
    }

    @Test(arguments: [
        (RunwareProblem.noKey, RetryAdvice.onRequest), (.cliNotSignedIn, .onRequest),
        (.cliConfigUnreadable, .onRequest),
        (.invalidKey, .onRequest), (.notPermitted, .onRequest), (.badRequest(code: nil, message: nil), .onRequest),
        (.unreachable, .backoff), (.unreadable, .backoff), (.tooLarge, .backoff), (.keychain, .backoff),
        (.rateLimited, .backoff),
    ])
    func `retry advice`(problem: RunwareProblem, advice: RetryAdvice) {
        #expect(RunwareAPI.retryAdvice(for: problem, now: now) == advice)
    }

    // MARK: Activity

    private var window: ClosedRange<UTCDay> { RunwareActivity.window(endingAt: now) }

    @Test func `activity covers 30 UTC days ending today, gaps unreported`() throws {
        let json = """
            "usage":{"timeseries":{"data":[{"date":"2026-10-21","count":40,"spend":1.5},
              {"date":"2026-10-19","count":7,"spend":"bad"},{"date":"2026-09-01","count":9,"spend":1},
              {"date":"nope","count":1}],"meta":{"totalRequests":47,"totalSpend":1.5}},
            "model":{"data":[{"model":"runware:100@1","modelName":"FLUX Schnell","count":7,"spend":0.5},
              {"model":"runware:101@1","count":40,"spend":1.0},{"modelName":"No AIR","count":1}]}}
            """
        let activity = try RunwareAPI.activity(answer(json), taskUUID: uuid, window: window, fetchedAt: now).get()
        #expect(activity.days.count == 30)
        #expect(activity.days.first?.day == UTCDay(iso: "2026-09-22"))
        #expect(activity.days.last == RunwareDay(day: UTCDay(now), requests: 40, spend: Decimal(string: "1.5")!))
        // An unreadable spend keeps its requests.
        #expect(activity.days[27] == RunwareDay(day: UTCDay(iso: "2026-10-19")!, requests: 7, spend: nil))
        #expect(!activity.days[28].isReported)
        #expect(activity.models.map(\.air) == ["runware:101@1", "runware:100@1"])
        #expect(activity.models[1].displayName == "FLUX Schnell" && activity.models[0].displayName == "runware:101@1")
        #expect(activity.modelsByDay == nil)
        #expect(activity.totalRequests == 47 && activity.totalSpend == Decimal(string: "1.5")!)
        #expect(activity.days(last: 99).count == 30 && activity.days(last: 0).count == 1)
        #expect(activity.days(last: 7).last?.day == UTCDay(now))
        #expect(activity.isPartial(UTCDay(now)))
        #expect(!activity.isBehind(at: now) && activity.isBehind(at: now.addingTimeInterval(86_400)))
    }

    @Test func `models broken down by day are kept by day too`() throws {
        let json = """
            "usage":{"model":{"data":[{"date":"2026-10-20","model":"a:1@1","count":2,"spend":1},
              {"date":"2026-10-21","model":"a:1@1","count":3,"spend":2},{"date":"2026-10-21","model":"b:1@1","count":1,"spend":5}]}}
            """
        let activity = try RunwareAPI.activity(answer(json), taskUUID: uuid, window: window, fetchedAt: now).get()
        #expect(activity.models.map(\.air) == ["b:1@1", "a:1@1"])
        #expect(activity.models[1].requests == 5 && activity.models[1].spend == 3)
        let today = RunwareDayModels(day: UTCDay(now), activity: activity)
        #expect(today.models.map(\.requests) == [1, 3])
        // A day without models in a by-day breakdown has none, not the whole window's.
        #expect(RunwareDayModels(day: UTCDay(iso: "2026-10-19")!, activity: activity).models.isEmpty)
        #expect(activity.totalRequests == nil)
    }

    // MARK: Model search

    @Test func `model pages read nested results, skip those without an AIR, and keep one of each`() throws {
        let rows = (0..<50).map { #"{"name":"M\#($0)","air":"civitai:\#($0)@1","category":"wildcard"}"# }
        let json =
            #"{"data":[{"taskType":"modelSearch","taskUUID":"\#(uuid.uuidString)","totalResults":120,"results":["#
            + rows.joined(separator: ",") + #",{"name":"no air"},{"air":"civitai:0@1"}]}]}"#
        let page = try RunwareAPI.modelPage(response(json), taskUUID: uuid, query: RunwareModelQuery()).get()
        #expect(page.models.count == 50)
        #expect(page.models[0].category == "wildcard")
        #expect(page.total == 120)
        #expect(page.nextOffset == 52)
        let last = RunwareModelPage(models: [], entryCount: 50, total: 120, query: RunwareModelQuery(offset: 100))
        #expect(last.nextOffset == nil)
        let short = RunwareModelPage(models: [], entryCount: 10, total: nil, query: RunwareModelQuery())
        #expect(short.nextOffset == nil)
    }

    @Test func `a model without a name is called by its AIR`() throws {
        let json =
            #"{"data":[{"taskUUID":"\#(uuid.uuidString)","results":[{"air":"runware:101@1","defaultCFG":7.5,"defaultWidth":1024}]}]}"#
        let model = try #require(
            try RunwareAPI.modelPage(response(json), taskUUID: uuid, query: RunwareModelQuery()).get().models.first)
        #expect(model.name == "runware:101@1" && model.defaultCFG == 7.5 && model.defaultWidth == 1024)
        #expect(model.requestJSON == #"{"model":"runware:101@1"}"#)
    }

    // MARK: Requests

    @Test func `requests are POSTed arrays of read-only tasks, with the key only in the header`() throws {
        let requests = [
            RunwareAPI.detailsRequest(key: "rw_secret", taskUUID: UUID(), userAgent: "Test"),
            RunwareAPI.activityRequest(
                key: "rw_secret", window: window, groupBy: [.date, .model], taskUUID: UUID(), userAgent: "Test"),
            RunwareAPI.modelSearchRequest(
                key: "rw_secret", query: RunwareModelQuery(search: "flux", category: "lora", offset: 50),
                taskUUID: UUID(), userAgent: "Test"),
        ]
        // Spelled out rather than read from the allowlist, so widening it to a paid task fails here.
        let readOnly: Set = ["accountManagement", "modelSearch"]
        #expect(RunwareAPI.readOnlyTaskTypes == readOnly)
        var uuids = Set<String>()
        for request in requests {
            #expect(request.httpMethod == "POST")
            #expect(request.url == RunwareAPI.endpoint)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer rw_secret")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let text = String(decoding: try #require(request.httpBody), as: UTF8.self)
            #expect(!text.contains("rw_secret") && request.url?.absoluteString.contains("rw_secret") == false)
            let tasks = try body(request)
            #expect(tasks.count == 1)
            #expect(readOnly.contains(try #require(tasks[0]["taskType"] as? String)))
            uuids.insert(try #require(tasks[0]["taskUUID"] as? String))
        }
        #expect(uuids.count == 3)
        let activity = try body(requests[1])[0]
        #expect(activity["timezone"] as? String == "UTC")
        #expect(activity["startDate"] as? String == "2026-09-22" && activity["endDate"] as? String == "2026-10-21")
        #expect(activity["groupBy"] as? [String] == ["date", "model"])
        let search = try body(requests[2])[0]
        #expect(search["search"] as? String == "flux" && search["category"] as? String == "lora")
        #expect(search["offset"] as? Int == 50)
        #expect((search["limit"] as? Int).map { $0 <= 100 } == true)
        let empty = try body(
            RunwareAPI.modelSearchRequest(
                key: "k", query: RunwareModelQuery(search: "  "), taskUUID: UUID(), userAgent: "T")
        )[0]
        #expect(empty["search"] == nil && empty["offset"] == nil)
    }
}
