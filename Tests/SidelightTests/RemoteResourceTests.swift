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
        try? await Task.sleep(for: .milliseconds(20))
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
        try? await Task.sleep(for: .milliseconds(30))
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
        try? await Task.sleep(for: .milliseconds(20))
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
        try? await Task.sleep(for: .milliseconds(30))
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
        try? await Task.sleep(for: .milliseconds(30))
        #expect(attempts == 1)
        resource.policy = nil
        resource.policy = .every(.milliseconds(1))
        try? await Task.sleep(for: .milliseconds(30))
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
        try? await Task.sleep(for: .milliseconds(20))
        #expect(resource.value == nil)
        await answers.answer(20)
        #expect(await eventually { resource.value == 20 && !resource.isFetching })
        resource.policy = nil
    }
}
