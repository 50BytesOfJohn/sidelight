import Foundation
import Testing

@testable import Sidelight
@testable import SidelightCore

struct RemoteResourceTests {
    @Test func `no demand makes no fetch manual initial load coalesces and resumes cache`() async {
        let answers = Answers<Int>()
        let resource = RemoteResource<Int, OpenRouterProblem>()
        resource.fetch = { .success(await answers.next()) }
        resource.refreshNow()
        await settle()
        #expect(answers.callCount == 0)
        resource.policy = .manual
        #expect(await eventually { answers.pendingCount == 1 })
        for _ in 0..<10 { resource.refreshNow() }
        #expect(answers.callCount == 1 && resource.isFetching)
        await answers.answer(42)
        #expect(await eventually { resource.value == 42 && !resource.isFetching })
        resource.policy = nil
        resource.policy = .manual
        resource.refreshNow()
        await settle()
        #expect(answers.callCount == 1)
        #expect(resource.value == 42)
        resource.policy = nil
    }

    @Test func `cancelled older answer cannot overwrite restarted resource or spinner`() async {
        let answers = Answers<Int>()
        let resource = RemoteResource<Int, OpenRouterProblem>()
        resource.fetch = { .success(await answers.next()) }
        resource.policy = .manual
        #expect(await eventually { answers.pendingCount == 1 })
        resource.policy = nil
        resource.policy = .manual
        #expect(await eventually { answers.pendingCount == 2 })
        await answers.answer(1)
        await settle()
        #expect(resource.value == nil && resource.isFetching)
        await answers.answer(2)
        #expect(await eventually { resource.value == 2 && !resource.isFetching })
        resource.policy = nil
    }

    @Test func `failure keeps last success timestamp and auth pause survives resume`() async {
        var attempt = 0
        let resource = RemoteResource<Int, OpenRouterProblem>(manualGap: .zero)
        resource.fetch = {
            attempt += 1
            return attempt == 1 ? .success(42) : .failure(.invalidKey, retry: .onRequest)
        }
        resource.policy = .every(.seconds(60))
        #expect(await eventually { resource.value == 42 && !resource.isFetching })
        let fetchedAt = resource.fetchedAt
        resource.refreshNow()
        #expect(await eventually { resource.problem == .invalidKey && !resource.isFetching })
        resource.policy = nil
        resource.policy = .every(.seconds(60))
        await settle()
        #expect(attempt == 2)
        #expect(resource.value == 42 && resource.fetchedAt == fetchedAt)
        resource.policy = nil
    }

    @Test func `manual refresh cannot bypass server cooldown`() async {
        var attempts = 0
        let resource = RemoteResource<Int, OpenRouterProblem>(manualGap: .zero, firstRetryDelay: .milliseconds(1))
        resource.fetch = {
            attempts += 1
            return .failure(.rateLimited, retry: .notBefore(.now.addingTimeInterval(60)))
        }
        resource.policy = .every(.milliseconds(1))
        #expect(await eventually { resource.problem == .rateLimited && !resource.isFetching })
        for _ in 0..<10 { resource.refreshNow() }
        await settle()
        #expect(attempts == 1)
        resource.policy = nil
        resource.policy = .every(.milliseconds(1))
        await settle()
        #expect(attempts == 1)
        resource.policy = nil
    }

    @Test func `reset prevents prior fetch publication and starts fresh generation`() async {
        let answers = Answers<Int>()
        let resource = RemoteResource<Int, OpenRouterProblem>()
        resource.fetch = { .success(await answers.next()) }
        resource.policy = .manual
        #expect(await eventually { answers.pendingCount == 1 })
        resource.reset()
        #expect(await eventually { answers.pendingCount == 2 })
        await answers.answer(10)
        await settle()
        #expect(resource.value == nil)
        await answers.answer(20)
        #expect(await eventually { resource.value == 20 && !resource.isFetching })
        resource.policy = nil
    }
}

extension RemoteResourceTests {
    @Test func `overdue UTC resume fetches once immediately and anchors at response time`() async {
        var now = Date(iso8601: "2026-10-12T12:00:00Z")!
        var attempts = 0
        let resource = RemoteResource<Int, OpenRouterProblem>(now: { now })
        resource.fetch = {
            attempts += 1
            return .success(attempts, at: now)
        }
        resource.policy = .dailyUTC(delay: .seconds(600))
        #expect(await eventually { resource.value == 1 && !resource.isFetching })
        resource.policy = nil
        now = Date(iso8601: "2026-10-14T12:00:00Z")!
        resource.policy = .dailyUTC(delay: .seconds(600))
        #expect(await eventually { resource.value == 2 && !resource.isFetching })
        #expect(resource.fetchedAt == now)
        await settle()
        #expect(attempts == 2)
        resource.policy = nil
    }

    @Test func `explicit response date is preserved even if delivery crosses midnight`() async {
        let responseDate = Date(iso8601: "2026-10-12T23:59:59Z")!
        let deliveryDate = Date(iso8601: "2026-10-13T00:00:01Z")!
        let resource = RemoteResource<Int, OpenRouterProblem>(now: { deliveryDate })
        resource.fetch = { .success(7, at: responseDate) }
        resource.policy = .manual
        #expect(await eventually { resource.value == 7 && !resource.isFetching })
        #expect(resource.fetchedAt == responseDate)
        resource.policy = nil
    }
}
