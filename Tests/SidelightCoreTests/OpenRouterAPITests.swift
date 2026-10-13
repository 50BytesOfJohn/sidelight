import Foundation
import Testing

@testable import SidelightCore

/// Synthetic API answers exercise documented shapes; they are not private-account captures.
struct OpenRouterAPITests {
    let now = Date(timeIntervalSince1970: 1_791_849_600)  // 2026-10-13 UTC

    private func response(_ json: String, status: Int = 200) -> HTTP.Response {
        HTTP.Response(status: status, body: Data(json.utf8))
    }

    @Test func `public catalogue request never contains authorization or pagination`() throws {
        let request = OpenRouterAPI.modelsRequest(userAgent: "Sidelight/Test")
        let url = try #require(request.url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.host == "openrouter.ai")
        #expect(url.path == "/api/v1/models")
        #expect(query == [URLQueryItem(name: "output_modalities", value: "all")])
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Sidelight/Test")
    }

    @Test func `activity uses one account request or explicit key scope`() throws {
        let hash = String(repeating: "a", count: 64)
        let account = OpenRouterAPI.activityRequest(key: "fixture", keyHash: nil, userAgent: "Test")
        let scoped = OpenRouterAPI.activityRequest(key: "fixture", keyHash: hash, userAgent: "Test")
        #expect(account.url?.query == nil)
        #expect(account.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        let components = try #require(scoped.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(components.queryItems == [URLQueryItem(name: "api_key_hash", value: hash)])
        let page = OpenRouterAPI.keysRequest(key: "fixture", offset: 100, userAgent: "Test")
        #expect(page.url?.query?.contains("offset=100") == true)
        #expect(page.url?.query?.contains("include_disabled=true") == true)
    }

    @Test(arguments: ["", "../credits", "a?x=1", "é", "nothex", "123"])
    func `selected key hash must be 64 hexadecimal characters`(hash: String) {
        #expect(!OpenRouterAPI.isPlausibleHash(hash))
        #expect(OpenRouterAPI.keyRequest(key: "fixture", hash: hash, userAgent: "Test") == nil)
    }

    @Test func `balance subtracts usage with decimal precision and preserves negatives`() throws {
        let result = OpenRouterAPI.balance(
            response(#"{"data":{"total_credits":"1.0000001","total_usage":"1.0000002","limit":999}}"#),
            fetchedAt: now)
        let balance = try result.get()
        #expect(balance.remaining == Decimal(string: "-0.0000001"))
        #expect(balance.fetchedAt == now)
    }

    @Test(arguments: [
        #"{"data":{"total_credits":10}}"#, #"{"data":{"total_usage":2}}"#,
        #"{"data":{"total_credits":null,"total_usage":2}}"#,
        #"{"data":{"total_credits":"NaN","total_usage":2}}"#,
        #"{"data":{"total_credits":"12garbage","total_usage":2}}"#,
    ])
    func `partial or malformed balance never becomes money`(json: String) {
        #expect(OpenRouterAPI.balance(response(json), fetchedAt: now) == .failure(.unreadable))
    }

    @Test func `catalogue tolerates odd fields deduplicates IDs and retains unknown modalities`() throws {
        let json = #"""
            {"data":[null,{},
              {"id":"z/unknown","name":null,"created":null,"context_length":-1,
               "architecture":{"input_modalities":["future"],"output_modalities":["future"]},
               "pricing":{"prompt":"-1","completion":null}},
              {"id":"a/text","created":100,"architecture":{"input_modalities":["text"],"output_modalities":["text"]}},
              {"id":"a/text","created":200}]}
            """#
        let catalogue = try OpenRouterAPI.catalogue(response(json), fetchedAt: now).get()
        #expect(catalogue.models.map(\.id) == ["a/text", "z/unknown"])
        let unknown = try #require(catalogue.models.last)
        #expect(unknown.name == unknown.id)
        #expect(unknown.contextLength == nil)
        #expect(unknown.inputPrice == .varies)
        #expect(catalogue.count(.all) == 2)
        #expect(catalogue.count(.textOutput) == 1)
    }

    @Test func `activity aggregates endpoint rows without mixing BYOK or inventing missing days`() throws {
        let date = try #require(Date(iso8601: "2026-10-13T00:00:01Z"))
        let json = #"""
            {"data":[
              {"date":"2026-10-12","usage":"0.1","byok_usage_inference":"0.7"},
              {"date":"2026-10-12 00:00:00","usage":"0.2","byok_usage_inference":"0.8"},
              {"date":"2026-10-13","usage":999},
              {"date":"2026-09-01","usage":999}]}
            """#
        let activity = try OpenRouterAPI.activity(response(json), key: nil, fetchedAt: date).get()
        let days = activity.days(7)
        #expect(days.count == 7)
        #expect(days.last?.day.description == "2026-10-12")
        #expect(days.last?.usage == Decimal(string: "0.3"))
        #expect(days.last?.byokUsage == Decimal(string: "1.5"))
        #expect(days.dropLast().allSatisfy { !$0.isReported && $0.usage == nil })
        #expect(OpenRouterActivity.total(of: days) == Decimal(string: "0.3"))
        #expect(OpenRouterActivity.byokTotal(of: days) == Decimal(string: "1.5"))
        #expect(!activity.isBehind(at: date))
        #expect(activity.isBehind(at: date.addingTimeInterval(86_400)))
    }

    @Test(arguments: [
        #"{"data":[{"date":"2026-10-12","usage":1},{}]}"#,
        #"{"data":[{"date":"2026-02-30","usage":1}]}"#,
        #"{"data":[{"date":"2026-10-12","usage":"1oops"}]}"#,
        #"{"data":[{"date":"2026-10-12","usage":1,"byok_usage_inference":"bad"}]}"#,
    ])
    func `partial financial activity cannot claim a complete total`(json: String) {
        #expect(OpenRouterAPI.activity(response(json), key: nil, fetchedAt: now) == .failure(.unreadable))
    }

    @Test func `key metadata retains disabled expired selections and management capability`() throws {
        let hash = String(repeating: "b", count: 64)
        let json = """
            {"data":[{"hash":"\(hash)","name":"Laptop","disabled":true,"expires_at":"2026-10-01T00:00:00Z"}]}
            """
        let keys = try OpenRouterAPI.keys(response(json)).get()
        let key = try #require(keys.first)
        #expect(key.id == hash)
        #expect(key.isDisabled)
        #expect(key.isExpired(at: now))
        #expect(OpenRouterAPI.key(response("{}", status: 404)) == .failure(.keyNotFound))
        #expect(
            try OpenRouterAPI.keyCheck(response(#"{"data":{"is_management_key":true}}"#)).get().isManagementKey == true)
        #expect(
            try OpenRouterAPI.keyCheck(response(#"{"data":{"is_provisioning_key":false}}"#)).get().isManagementKey
                == false)
    }

    @Test(arguments: [401, 403, 400, 429, 503])
    func `HTTP failures remain explicit and terminal failures do not auto retry`(status: Int) {
        let result = OpenRouterAPI.balance(response("{}", status: status), fetchedAt: now)
        guard case .failure(let problem) = result else {
            Issue.record("HTTP \(status) was accepted")
            return
        }
        let advice = OpenRouterAPI.retryAdvice(for: problem, headers: ["rEtRy-AfTeR": "120"], now: now)
        #expect(advice == (status == 429 || status == 503 ? .notBefore(now.addingTimeInterval(120)) : .onRequest))
    }

    @Test func `response size and retry date bounds are enforced`() {
        let huge = HTTP.Response(status: 200, body: Data(repeating: 32, count: OpenRouterAPI.catalogueSizeLimit + 1))
        if case .failure(let problem) = OpenRouterAPI.catalogue(huge, fetchedAt: now) {
            #expect(problem == .tooLarge)
        } else {
            Issue.record("Oversized catalogue accepted")
        }
        #expect(RetryAfter.date(in: ["Retry-After": "999999"], now: now) == now.addingTimeInterval(21_600))
        #expect(RetryAfter.date(in: ["Retry-After": "-1"], now: now) == nil)
        let reference = Date(timeIntervalSince1970: 0)
        #expect(
            RetryAfter.date(in: ["Retry-After": "Thu, 01 Jan 1970 00:02:00 GMT"], now: reference)
                == reference.addingTimeInterval(120))
    }
}
