import Foundation
import Synchronization
import Testing

@testable import Sidelight
@testable import SidelightCore

struct ClaudeCodeServiceTests {
    private let work = AccountID(rawValue: "work")
    private let workProfile = ClaudeCodeProfile(configDirectory: "/tmp/claude-work")

    @Test func `one reader for each account widgets use, fetching as often as they ask`() {
        let service = ClaudeCodeService(accounts: AccountAccess(secret: { _ in nil }))
        service.demand = [
            .claudeCodeApp: ClaudeCodeNeeds(profile: .standard, refreshMinutes: 5),
            work: ClaudeCodeNeeds(profile: workProfile),
        ]
        let standard = service.account(.claudeCodeApp)
        #expect(standard?.profile == .standard && standard?.refreshInterval == .seconds(300))
        #expect(service.account(work)?.profile == workProfile && service.account(work)?.refreshInterval == nil)

        // Still the same reader, with what it read, as long as a widget uses the account.
        service.demand = [.claudeCodeApp: ClaudeCodeNeeds(profile: .standard, refreshMinutes: 15)]
        #expect(service.account(.claudeCodeApp) === standard)
        #expect(standard?.refreshInterval == .seconds(900))
        #expect(service.account(work) == nil)
    }

    @Test func `a check's answer from Anthropic is taken in only where someone opted in to asking`() {
        let reported = Mutex<[AccountStatus?]>([])
        let account = ClaudeCodeAccount(id: work, profile: workProfile) { status in
            reported.withLock { $0.append(status) }
        }
        let usage = ClaudeCodeUsage(session: nil, weekly: nil, capturedAt: .now, source: .anthropic)
        account.checked(.success(usage))
        #expect(account.anthropicUsage == nil && reported.withLock { $0 }.isEmpty)

        account.refreshInterval = .seconds(300)
        account.checked(.success(usage))
        #expect(account.anthropicUsage == usage)
        account.checked(.failure(.signInExpired))
        #expect(account.anthropicProblem == .signInExpired)
        #expect(reported.withLock { $0 } == [.connected, .expired])
    }

    @Test func `each account's status line has a file of its own`() {
        let standard = ClaudeCodeAccount(id: .claudeCodeApp, profile: .standard)
        let other = ClaudeCodeAccount(id: work, profile: workProfile)
        #expect(standard.statusLineFileURL.lastPathComponent == "status-line.json")
        #expect(other.statusLineFileURL.lastPathComponent == "status-line-bfc1769a.json")
        #expect(
            other.statusLineFileURL.deletingLastPathComponent()
                == standard.statusLineFileURL.deletingLastPathComponent())
    }
}
