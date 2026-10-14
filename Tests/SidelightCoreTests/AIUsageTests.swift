import Foundation
import Testing

@testable import SidelightCore

struct AIUsageSettingsTests {
    private let work = AccountID(rawValue: "C1A0DE00-0000-4000-8000-000000000001")

    @Test func `defaults show every agent's block as used, with nothing fetched`() {
        let settings = AIUsageSettings()
        #expect(settings.blocks.shownBlocks == [.codex, .claudeCode, .cursor])
        #expect(settings.preset == .everyAgent)
        #expect(settings.reading == .used)
        #expect(settings.showsOtherLimits)
        #expect(!settings.refreshesClaudeFromAnthropic)
        #expect(!settings.refreshesCursor)
        #expect(settings.claudeRefreshMinutesIfOptedIn == nil)
        #expect(settings.cursorRefreshMinutesIfOptedIn == nil)
    }

    @Test func `a block is stored as its agent and ID`() {
        let block = AIUsageBlock(.claudeCode)
        #expect(block.rawValue == "claudeCode:\(block.uuid.uuidString)")
        #expect(block.id == block.rawValue)
        #expect(AIUsageBlock(rawValue: block.rawValue) == block)
        #expect(AIUsageBlock(rawValue: "gemini:\(block.uuid.uuidString)") == nil)
        #expect(AIUsageBlock(rawValue: "claudeCode") == nil)
        #expect(AIUsageBlock(rawValue: "claudeCode:not-a-uuid") == nil)
    }

    @Test func `a widget round-trips through config json, with each block's label and account`() throws {
        var settings = AIUsageSettings(
            blocks: [.claudeCode, .cursor], options: [.claudeCode: AIUsageBlockOptions(label: "Personal")],
            reading: .remaining, showsOtherLimits: false, refreshesClaudeFromAnthropic: true,
            claudeRefreshMinutes: 15, refreshesCursor: true, cursorRefreshMinutes: 30)
        settings.addBlock(.claudeCode, options: AIUsageBlockOptions(label: "Work", account: work))
        var configuration = AppConfiguration()
        let widget = WidgetInstance(settings: .aiUsage(settings), showsInBar: false)
        configuration.sections = [PanelSection(widgets: [widget])]
        let json = try configuration.json()
        #expect(String(decoding: json, as: UTF8.self).contains(#""kind" : "aiUsage""#))
        let decoded = try AppConfiguration(json: json)
        #expect(decoded.widgets == [widget])
    }

    @Test func `a widget saved without settings loads with defaults`() throws {
        let json = #"""
            {"id":"5B2B0F7E-6C1B-4F4A-9C11-0E8C3D1A2B3C","kind":"aiUsage","showsInSidePanel":true,"showsInBar":true}
            """#
        let widget = try JSONDecoder().decode(WidgetInstance.self, from: Data(json.utf8))
        #expect(widget.settings == .aiUsage(AIUsageSettings()))
    }

    @Test func `settings saved before blocks load with every agent, keeping how limits read and fetch`() throws {
        let json = #"""
            {"providers":["codex","cursor"],"claudeAccount":"work","reading":"remaining","showsOtherLimits":false,
             "refreshesClaudeFromAnthropic":true,"claudeRefreshMinutes":15,"refreshesCursor":true,
             "cursorRefreshMinutes":60}
            """#
        let settings = try JSONDecoder().decode(AIUsageSettings.self, from: Data(json.utf8))
        #expect(
            settings
                == AIUsageSettings(
                    reading: .remaining, showsOtherLimits: false, refreshesClaudeFromAnthropic: true,
                    claudeRefreshMinutes: 15, refreshesCursor: true, cursorRefreshMinutes: 60))
    }

    @Test func `unknown blocks, readings and stray options are skipped, and intervals moved into range`() throws {
        let kept = AIUsageBlock.claudeCode.rawValue
        let json = #"""
            {"blocks":[{"block":"gemini:\#(UUID().uuidString)","shown":true},{"block":"\#(kept)","shown":true}],
             "blockOptions":{"\#(kept)":{"label":"","accountID":42},"codex:\#(UUID().uuidString)":{"label":"Gone"}},
             "reading":"sideways","claudeRefreshMinutes":0}
            """#
        let settings = try JSONDecoder().decode(AIUsageSettings.self, from: Data(json.utf8))
        #expect(settings.blocks.shownBlocks == [.claudeCode])
        #expect(settings.blockOptions.keys.sorted() == [kept])
        #expect(settings.options(.claudeCode) == AIUsageBlockOptions())
        #expect(settings.reading == .used)
        #expect(settings.claudeRefreshMinutes == 1)
        #expect(settings.cursorRefreshMinutes == 15)
    }

    @Test func `one unreadable block's options don't lose the others'`() throws {
        let codex = AIUsageBlock.codex.rawValue
        let claude = AIUsageBlock.claudeCode.rawValue
        let cursor = AIUsageBlock.cursor.rawValue
        let json = #"""
            {"blockOptions":{"\#(codex)":{"label":42},"\#(claude)":{"label":"Work"},"\#(cursor)":"odd"}}
            """#
        let settings = try JSONDecoder().decode(AIUsageSettings.self, from: Data(json.utf8))
        #expect(settings.options(.claudeCode).label == "Work")
        #expect(settings.options(.codex) == AIUsageBlockOptions())
        #expect(settings.options(.cursor) == AIUsageBlockOptions())
    }

    @Test func `blocks of two agents sharing a UUID keep apart`() {
        let uuid = UUID()
        let claude = AIUsageBlock(.claudeCode, uuid: uuid)
        let cursor = AIUsageBlock(.cursor, uuid: uuid)
        var settings = AIUsageSettings(blocks: [claude, cursor])
        settings.setOptions(AIUsageBlockOptions(label: "Work"), for: claude)
        #expect(claude.id != cursor.id)
        #expect(settings.options(cursor) == AIUsageBlockOptions())
        settings.removeBlock(cursor)
        #expect(settings.options(claude).label == "Work")
    }

    @Test func `the same agent can be added again, and removing a block forgets its options`() {
        var settings = AIUsageSettings(blocks: [.claudeCode])
        let work = settings.addBlock(.claudeCode, options: AIUsageBlockOptions(label: "Work", account: work))
        #expect(settings.blocks.shownBlocks == [.claudeCode, work])
        #expect(settings.options(work).label == "Work")
        #expect(settings.preset == nil)

        settings.removeBlock(work)
        #expect(!settings.blocks.contains(work))
        #expect(settings.blockOptions.isEmpty)
        settings.setOptions(AIUsageBlockOptions(label: "Back"), for: work)
        #expect(settings.blockOptions.isEmpty)
    }

    @Test func `a preset brings its blocks back as they were left`() {
        var settings = AIUsageSettings(
            blocks: [.claudeCode], options: [.claudeCode: AIUsageBlockOptions(label: "Personal")])
        settings.removeBlock(.claudeCode)
        settings.setOptions(AIUsageBlockOptions(label: "Lost"), for: .claudeCode)
        settings.apply(.codexAndClaude)
        #expect(settings.blocks.shownBlocks == [.codex, .claudeCode])
        #expect(settings.preset == .codexAndClaude)
        #expect(settings.options(.claudeCode) == AIUsageBlockOptions())

        settings.setOptions(AIUsageBlockOptions(label: "Personal"), for: .claudeCode)
        settings.apply(.everyAgent)
        settings.apply(.codexAndClaude)
        #expect(settings.blocks.shownBlocks == [.codex, .claudeCode])
        #expect(settings.blocks.entries.map(\.block) == [.codex, .claudeCode, .cursor])
        #expect(settings.options(.claudeCode).label == "Personal")
    }

    @Test func `an opt-in only counts for an agent with a block shown`() {
        var settings = AIUsageSettings(
            blocks: [.codex, .claudeCode, .cursor], refreshesClaudeFromAnthropic: true, claudeRefreshMinutes: 2,
            refreshesCursor: true)
        settings.blocks.setShown(.claudeCode, false)
        settings.blocks.setShown(.cursor, false)
        #expect(settings.shownProviders == [.codex])
        #expect(settings.claudeRefreshMinutesIfOptedIn == nil)
        #expect(settings.cursorRefreshMinutesIfOptedIn == nil)
    }

    @Test func `each block of an agent with accounts names its account, and can forget it`() {
        var settings = AIUsageSettings(blocks: [.codex, .claudeCode])
        let workBlock = settings.addBlock(.claudeCode, options: AIUsageBlockOptions(label: "Work", account: work))
        settings.blocks.setShown(.claudeCode, false)
        #expect(settings.accountReferences(shownOnly: true).map(\.account) == [work])
        #expect(settings.accountReferences(shownOnly: false).map(\.account) == [nil, work])
        #expect(settings.accountReferences(shownOnly: false).allSatisfy { $0.provider == .claudeCode })

        let forgot = settings.forgetAccount(work)
        #expect(forgot)
        #expect(settings.options(workBlock) == AIUsageBlockOptions(label: "Work"))
        let forgotAgain = settings.forgetAccount(work)
        #expect(!forgotAgain)
    }

    @Test func `Codex settings keep reading as before`() throws {
        let settings = try JSONDecoder().decode(CodexSettings.self, from: Data(#"{"limitReading":"used"}"#.utf8))
        #expect(settings.limitReading == UsageReading.used)
        let encoded = try JSONEncoder().encode(settings)
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""limitReading":"used""#))
    }
}

struct UsageServiceDemandTests {
    private func configuration(_ widgets: [WidgetInstance]) -> AppConfiguration {
        var configuration = AppConfiguration()
        configuration.sections = [PanelSection(widgets: widgets)]
        return configuration
    }

    private let claudeOptIn = WidgetInstance(
        settings: .claudeCode(ClaudeCodeSettings(refreshesFromAnthropic: true, refreshMinutes: 15)))
    private let cursorOptIn = WidgetInstance(
        settings: .cursor(CursorSettings(refreshesFromCursor: true, refreshMinutes: 30)))

    /// The default Claude account fetched from Anthropic every `minutes`.
    private func claudeDefault(every minutes: Int?) -> [AccountID: ClaudeCodeNeeds] {
        [.claudeCodeApp: ClaudeCodeNeeds(profile: .standard, refreshMinutes: minutes)]
    }

    @Test func `an AI Usage widget alone runs every agent it shows, without fetching`() {
        let demand = configuration([WidgetInstance(kind: .aiUsage)]).serviceDemand(at: [.left])
        #expect(demand.usage == UsageServiceDemand(providers: [.codex, .claudeCode, .cursor]))
        #expect(demand.kinds == [.aiUsage])
    }

    @Test func `it starts only the agents it shows`() {
        let widget = WidgetInstance(settings: .aiUsage(AIUsageSettings(blocks: [.claudeCode])))
        let demand = configuration([widget]).serviceDemand(at: [.right])
        #expect(demand.usage.providers == [.claudeCode])
    }

    @Test func `its own opt-ins fetch, for agents it shows`() {
        let widget = WidgetInstance(
            settings: .aiUsage(
                AIUsageSettings(
                    refreshesClaudeFromAnthropic: true, claudeRefreshMinutes: 5, refreshesCursor: true,
                    cursorRefreshMinutes: 60)))
        let opted = configuration([widget]).serviceDemand(at: [.left])
        #expect(opted.usage == UsageServiceDemand(providers: [.codex, .claudeCode, .cursor], cursorRefreshMinutes: 60))
        #expect(opted.claudeCode == claudeDefault(every: 5))

        let withoutCursor = WidgetInstance(
            settings: .aiUsage(
                AIUsageSettings(blocks: [.codex, .claudeCode], refreshesCursor: true, cursorRefreshMinutes: 5)))
        let demand = configuration([withoutCursor]).serviceDemand(at: [.left]).usage
        #expect(demand.cursorRefreshMinutes == nil)
        #expect(!demand.providers.contains(.cursor))
    }

    @Test func `standalone and AI Usage widgets share one service at the most frequent interval`() {
        let combined = WidgetInstance(
            settings: .aiUsage(
                AIUsageSettings(
                    blocks: [.claudeCode, .cursor], refreshesClaudeFromAnthropic: true, claudeRefreshMinutes: 5,
                    refreshesCursor: true, cursorRefreshMinutes: 60)))
        let demand = configuration([claudeOptIn, cursorOptIn, combined, WidgetInstance(kind: .codex)])
            .serviceDemand(at: [.left])
        #expect(
            demand.usage == UsageServiceDemand(providers: [.codex, .claudeCode, .cursor], cursorRefreshMinutes: 30))
        #expect(demand.claudeCode == claudeDefault(every: 5))
        #expect(demand.kinds == [.claudeCode, .cursor, .aiUsage, .codex])
    }

    @Test func `a hidden widget's opt-in doesn't fetch for one that's showing`() {
        var hidden = claudeOptIn
        hidden.showsInSidePanel = false
        hidden.showsInBar = false
        let combined = WidgetInstance(settings: .aiUsage(AIUsageSettings(blocks: [.claudeCode])))
        let demand = configuration([hidden, combined]).serviceDemand(at: [.left])
        #expect(demand.usage == UsageServiceDemand(providers: [.claudeCode]))
        #expect(demand.claudeCode == claudeDefault(every: nil))
    }

    @Test func `a widget shown only in the bar counts only for bars`() {
        let barOnly = WidgetInstance(
            settings: .aiUsage(AIUsageSettings(blocks: [.cursor], refreshesCursor: true)), showsInSidePanel: false)
        let config = configuration([barOnly])
        #expect(config.serviceDemand(at: [.left]).usage == UsageServiceDemand())
        #expect(
            config.serviceDemand(at: [.top]).usage == UsageServiceDemand(providers: [.cursor], cursorRefreshMinutes: 15)
        )
        #expect(config.serviceDemand(at: []).usage == UsageServiceDemand())
    }

    @Test func `removing or narrowing the AI Usage widget keeps what standalone widgets need`() {
        let combined = WidgetInstance(
            settings: .aiUsage(AIUsageSettings(refreshesClaudeFromAnthropic: true, claudeRefreshMinutes: 2)))
        let both = configuration([claudeOptIn, combined]).serviceDemand(at: [.left])
        #expect(both.usage.providers == [.codex, .claudeCode, .cursor])
        #expect(both.claudeCode == claudeDefault(every: 2))

        let removed = configuration([claudeOptIn]).serviceDemand(at: [.left])
        #expect(removed.usage == UsageServiceDemand(providers: [.claudeCode]))
        #expect(removed.claudeCode == claudeDefault(every: 15))

        var narrowed = combined
        narrowed.settings = .aiUsage(
            AIUsageSettings(blocks: [.codex], refreshesClaudeFromAnthropic: true, claudeRefreshMinutes: 2))
        let withoutClaude = configuration([claudeOptIn, narrowed]).serviceDemand(at: [.left])
        #expect(withoutClaude.usage == UsageServiceDemand(providers: [.codex, .claudeCode]))
        #expect(withoutClaude.claudeCode == claudeDefault(every: 15))

        var hidden = combined
        hidden.showsInSidePanel = false
        hidden.showsInBar = false
        let withHidden = configuration([claudeOptIn, hidden]).serviceDemand(at: [.left])
        #expect(withHidden.usage == removed.usage && withHidden.claudeCode == removed.claudeCode)
    }

    @Test func `the Widgets window runs everything, with every widget's opt-ins`() {
        var hidden = cursorOptIn
        hidden.showsInSidePanel = false
        hidden.showsInBar = false
        let demand = configuration([hidden, WidgetInstance(kind: .clock)])
            .serviceDemand(at: [], previewsEveryWidget: true)
        #expect(demand.kinds == Set(WidgetKind.allCases))
        #expect(
            demand.usage == UsageServiceDemand(providers: [.codex, .claudeCode, .cursor], cursorRefreshMinutes: 30))
    }

    @Test func `other kinds still drive their own services`() {
        let demand = configuration([WidgetInstance(kind: .calendar), WidgetInstance(kind: .system)])
            .serviceDemand(at: [.left])
        #expect(demand.kinds == [.calendar, .system])
        #expect(demand.usage == UsageServiceDemand())
    }

    @Test func `the configuration-wide intervals count AI Usage widgets too`() {
        let combined = WidgetInstance(
            settings: .aiUsage(AIUsageSettings(refreshesClaudeFromAnthropic: true, claudeRefreshMinutes: 2)))
        let config = configuration([claudeOptIn, cursorOptIn, combined])
        #expect(config.claudeCodeDemand(of: config.widgets) == claudeDefault(every: 2))
        #expect(config.cursorRefreshMinutes == 30)
    }
}

struct AIUsageSummaryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ used: Double, resetsIn hours: Double?, minutes: Int) -> RateLimitWindow {
        RateLimitWindow(
            usedPercent: used, resetsAt: hours.map { now.addingTimeInterval($0 * 3_600) }, durationMinutes: minutes)
    }

    private func codexState(
        primary: RateLimitWindow?, secondary: RateLimitWindow?, capturedMinutesAgo: Double = 0,
        source: CodexState.Source = .appServer
    ) -> CodexState {
        CodexState(
            source: source, account: .chatGPT(plan: "plus"),
            rateLimits: CodexRateLimits(primary: primary, secondary: secondary, planType: "plus"),
            limitsCapturedAt: now.addingTimeInterval(-capturedMinutesAgo * 60))
    }

    // MARK: Codex

    @Test func `Codex limits are named by length and led by the most used`() throws {
        let summary = AIUsageSummary.codex(
            codexState(
                primary: window(30, resetsIn: 2, minutes: 300), secondary: window(70, resetsIn: 50, minutes: 10_080)),
            plan: "Plus", now: now)
        #expect(summary.status == .limits)
        #expect(summary.limits.map(\.title) == ["5-hour", "Weekly"])
        #expect(summary.limits.map(\.shortTitle) == ["5h", "wk"])
        #expect(summary.limits.map(\.segments) == [5, 7])
        #expect(summary.lead(at: now)?.title == "Weekly")
        #expect(summary.others(at: now).map(\.title) == ["5-hour"])
        #expect(summary.freshness == .live)
        #expect(summary.plan == "Plus")
        #expect(summary.notice == nil)
    }

    @Test func `a window that has reset is unknown, not a full allowance`() throws {
        let state = codexState(
            primary: window(95, resetsIn: -0.5, minutes: 300), secondary: window(40, resetsIn: 30, minutes: 10_080))
        let summary = AIUsageSummary.codex(state, plan: nil, now: now)
        let session = try #require(summary.limits.first)
        #expect(session.hasReset(at: now))
        #expect(summary.warning(for: session, at: now) == nil)
        #expect(summary.lead(at: now)?.title == "Weekly")

        let allReset = AIUsageSummary.codex(
            codexState(
                primary: window(95, resetsIn: -1, minutes: 300), secondary: window(99, resetsIn: -1, minutes: 10_080)),
            plan: nil, now: now)
        #expect(allReset.lead(at: now)?.title == "5-hour")
        #expect(allReset.lead(at: now)?.hasReset(at: now) == true)
    }

    @Test func `a stop Codex reports counts whatever the percentages say`() {
        var state = codexState(primary: window(40, resetsIn: 2, minutes: 300), secondary: nil)
        state.rateLimits?.reachedType = "workspace_member_credits_depleted"
        let summary = AIUsageSummary.codex(state, plan: nil, now: now)
        #expect(summary.notice == .init("Workspace credits used up", severity: .critical))

        state.rateLimits?.reachedType = nil
        state.ordinaryUsageAllowed = nil
        #expect(AIUsageSummary.codex(state, plan: nil, now: now).notice == nil)
        state.ordinaryUsageAllowed = false
        #expect(AIUsageSummary.codex(state, plan: nil, now: now).notice?.text == "Usage limit reached")

        // A used-up limit already says why.
        state.rateLimits?.primary = window(100, resetsIn: 2, minutes: 300)
        state.rateLimits?.reachedType = "rate_limit_reached"
        let usedUp = AIUsageSummary.codex(state, plan: nil, now: now)
        #expect(usedUp.notice == nil)
        #expect(usedUp.lead(at: now).flatMap { usedUp.warning(for: $0, at: now) } == .usedUp)
    }

    @Test func `Codex freshness follows the app-server and its age`() {
        let limits = (window(50, resetsIn: 2, minutes: 300), window(20, resetsIn: 30, minutes: 10_080))
        let live = AIUsageSummary.codex(codexState(primary: limits.0, secondary: limits.1), plan: nil, now: now)
        #expect(live.freshness == .live)
        #expect(live.source == "codex app-server")

        let logged = AIUsageSummary.codex(
            codexState(primary: limits.0, secondary: limits.1, capturedMinutesAgo: 10, source: .rolloutFile),
            plan: nil, now: now)
        #expect(logged.freshness == .aged)
        #expect(logged.source == "Codex's session logs")

        let old = AIUsageSummary.codex(
            codexState(primary: limits.0, secondary: limits.1, capturedMinutesAgo: 45, source: .rolloutFile),
            plan: nil, now: now)
        #expect(old.freshness == .stale)

        var failing = codexState(primary: limits.0, secondary: limits.1, capturedMinutesAgo: 2)
        failing.problem = "rate limits unavailable"
        let failed = AIUsageSummary.codex(failing, plan: nil, now: now)
        #expect(failed.freshness == .stale)
        #expect(failed.notice == .init("codex app-server: rate limits unavailable", severity: .warning))
    }

    @Test func `forecasts only come from live numbers`() throws {
        // 2 of 5 hours gone, 80% used: runs out after 2.5 hours, well before the reset in 3.
        let fast = window(80, resetsIn: 3, minutes: 300)
        let live = AIUsageSummary.codex(codexState(primary: fast, secondary: nil), plan: nil, now: now)
        let limit = try #require(live.limits.first)
        guard case .runsOut = live.warning(for: limit, at: now) else {
            Issue.record("expected a forecast")
            return
        }
        let logged = AIUsageSummary.codex(
            codexState(primary: fast, secondary: nil, capturedMinutesAgo: 10, source: .rolloutFile), plan: nil, now: now
        )
        #expect(logged.warning(for: limit, at: now) == nil)
    }

    @Test func `Codex states without limits say why`() {
        var state = CodexState()
        #expect(AIUsageSummary.codex(state, plan: nil, now: now).status == .loading("Reading Codex usage…"))
        state.source = .unavailable
        guard case .setup = AIUsageSummary.codex(state, plan: nil, now: now).status else {
            Issue.record("Codex not found should ask for setup")
            return
        }
        state.source = .appServer
        state.problem = "boom"
        #expect(
            AIUsageSummary.codex(state, plan: nil, now: now).status
                == .failed(title: "Can't read Codex limits", detail: "boom"))
        state.account = .signedOut
        guard case .setup = AIUsageSummary.codex(state, plan: nil, now: now).status else {
            Issue.record("signed out should ask for setup")
            return
        }
        state.account = .apiKey
        guard case .noLimits = AIUsageSummary.codex(state, plan: nil, now: now).status else {
            Issue.record("an API key has no plan limits")
            return
        }
        state.account = .chatGPT(plan: nil)
        state.problem = nil
        state.rateLimits = CodexRateLimits(planType: "plus")
        guard case .noLimits = AIUsageSummary.codex(state, plan: nil, now: now).status else {
            Issue.record("no windows reported")
            return
        }
    }

    // MARK: Claude Code

    private func claudeUsage(
        session: RateLimitWindow?, weekly: RateLimitWindow?, minutesAgo: Double = 1,
        source: ClaudeCodeUsage.Source = .statusLine
    ) -> ClaudeCodeUsage {
        ClaudeCodeUsage(
            session: session, weekly: weekly, capturedAt: now.addingTimeInterval(-minutesAgo * 60), source: source)
    }

    @Test func `Claude's session and week read like the other agents' windows`() {
        let usage = claudeUsage(
            session: window(20, resetsIn: 1, minutes: 300), weekly: window(64, resetsIn: 72, minutes: 10_080))
        let summary = AIUsageSummary.claudeCode(
            usage: usage, plan: "Max", hasLoaded: true, anthropicProblem: nil, now: now)
        #expect(summary.status == .limits)
        #expect(summary.limits.map(\.title) == ["5-hour", "Weekly"])
        #expect(summary.lead(at: now)?.shortTitle == "wk")
        #expect(summary.freshness == .live)
        #expect(summary.source == "Claude Code's status line")
        #expect(summary.limits.first?.startsWithNextMessage == true)
    }

    @Test func `Claude's passed reset awaits new numbers instead of reading as unused`() throws {
        let usage = claudeUsage(
            session: window(90, resetsIn: -1, minutes: 300), weekly: window(30, resetsIn: -2, minutes: 10_080),
            minutesAgo: 400, source: .usageCache)
        let summary = AIUsageSummary.claudeCode(
            usage: usage, plan: nil, hasLoaded: true, anthropicProblem: nil, now: now)
        #expect(summary.limits.allSatisfy { $0.hasReset(at: now) })
        #expect(summary.limits.map(\.window.usedPercent) == [90, 30])
        #expect(summary.freshness == .aged)
        #expect(summary.source == "Claude Code's /usage")
    }

    @Test func `Claude's age only turns stale with a failing fetch`() {
        let usage = claudeUsage(
            session: window(20, resetsIn: 1, minutes: 300), weekly: nil, minutesAgo: 120, source: .anthropic)
        let aged = AIUsageSummary.claudeCode(usage: usage, plan: nil, hasLoaded: true, anthropicProblem: nil, now: now)
        #expect(aged.freshness == .aged)
        let stale = AIUsageSummary.claudeCode(
            usage: usage, plan: nil, hasLoaded: true, anthropicProblem: .unreachable, now: now)
        #expect(stale.freshness == .stale)
        #expect(stale.notice?.severity == .warning)
        // Fresh numbers from the status line outweigh a failing fetch.
        let fresh = AIUsageSummary.claudeCode(
            usage: claudeUsage(session: window(20, resetsIn: 1, minutes: 300), weekly: nil), plan: nil,
            hasLoaded: true, anthropicProblem: .unreachable, now: now)
        #expect(fresh.freshness == .live)
        #expect(fresh.notice == nil)
    }

    @Test func `Claude without numbers asks for its status line`() {
        #expect(
            AIUsageSummary.claudeCode(usage: nil, plan: nil, hasLoaded: false, anthropicProblem: nil, now: now).status
                == .loading("Reading Claude Code usage…"))
        guard
            case .setup = AIUsageSummary.claudeCode(
                usage: nil, plan: nil, hasLoaded: true, anthropicProblem: nil, now: now
            ).status
        else {
            Issue.record("expected setup")
            return
        }
        guard
            case .failed = AIUsageSummary.claudeCode(
                usage: nil, plan: nil, hasLoaded: true, anthropicProblem: .signInExpired, now: now
            ).status
        else {
            Issue.record("expected a failure")
            return
        }
    }

    // MARK: Cursor

    private func cursorUsage(auto: Double, api: Double, cycleEndsInDays days: Double) -> CursorUsage {
        let end = now.addingTimeInterval(days * 86_400)
        let cycle = DateInterval(start: end.addingTimeInterval(-30 * 86_400), end: end)
        let window = { (percent: Double) in
            RateLimitWindow(usedPercent: percent, resetsAt: end, durationMinutes: 30 * 24 * 60)
        }
        return CursorUsage(
            membershipType: "pro_plus", billingCycle: cycle,
            pools: [
                CursorUsagePool(kind: .cursorModels, window: window(auto)),
                CursorUsagePool(kind: .otherModels, window: window(api), message: "You've used 97%"),
            ],
            onDemand: CursorSpending(isEnabled: true, used: 0, limit: 2_000), fetchedAt: now.addingTimeInterval(-60))
    }

    @Test func `Cursor waits for this widget's own opt-in`() {
        let summary = AIUsageSummary.cursor(
            isConnected: false, usage: cursorUsage(auto: 10, api: 20, cycleEndsInDays: 10), problem: nil,
            isStale: false, now: now)
        #expect(summary.limits.isEmpty)
        guard case .setup(let title, _) = summary.status else {
            Issue.record("expected setup")
            return
        }
        #expect(title == "Not connected")
    }

    @Test func `Cursor pools read as billing-cycle limits for the whole account`() throws {
        let summary = AIUsageSummary.cursor(
            isConnected: true, usage: cursorUsage(auto: 10, api: 64, cycleEndsInDays: 10), problem: nil,
            isStale: false, now: now)
        #expect(summary.status == .limits)
        #expect(summary.limits.map(\.shortTitle) == ["Auto", "API"])
        #expect(summary.limits.allSatisfy { $0.isBillingCycle })
        #expect(summary.limits.map(\.segments) == [4, 4])
        #expect(summary.lead(at: now)?.title == "API models")
        #expect(summary.lead(at: now)?.explanation?.contains("You've used 97%") == true)
        #expect(summary.plan == "Pro+")
        #expect(summary.source == "cursor.com")
        #expect(summary.notice == nil)
    }

    @Test func `a new billing cycle awaits the next fetch`() {
        let summary = AIUsageSummary.cursor(
            isConnected: true, usage: cursorUsage(auto: 100, api: 80, cycleEndsInDays: -1), problem: nil,
            isStale: false, now: now)
        #expect(summary.status == .limits)
        #expect(summary.limits.allSatisfy { $0.hasReset(at: now) })
        #expect(summary.lead(at: now).flatMap { summary.warning(for: $0, at: now) } == nil)
        // A used-up pool from the last cycle says nothing about this one.
        #expect(summary.notice == nil)
    }

    @Test func `a used-up pool with on-demand says so`() {
        let summary = AIUsageSummary.cursor(
            isConnected: true, usage: cursorUsage(auto: 100, api: 40, cycleEndsInDays: 5), problem: nil,
            isStale: false, now: now)
        #expect(summary.lead(at: now)?.shortTitle == "Auto")
        #expect(summary.notice == .init("On-demand usage from here", severity: .info))
    }

    @Test func `Cursor problems ask for sign-in or report the failure`() {
        let signIn = AIUsageSummary.cursor(
            isConnected: true, usage: nil, problem: .notSignedIn, isStale: false, now: now)
        #expect(
            signIn.status == .setup(title: "Not signed in to Cursor", detail: CursorFetchProblem.notSignedIn.advice))
        let down = AIUsageSummary.cursor(isConnected: true, usage: nil, problem: .unreachable, isStale: false, now: now)
        #expect(down.status == .failed(title: "Can't reach cursor.com", detail: "Trying again later."))
        let loading = AIUsageSummary.cursor(isConnected: true, usage: nil, problem: nil, isStale: false, now: now)
        #expect(loading.status == .loading("Fetching Cursor usage…"))

        let stale = AIUsageSummary.cursor(
            isConnected: true, usage: cursorUsage(auto: 10, api: 20, cycleEndsInDays: 5), problem: .unreachable,
            isStale: true, now: now)
        #expect(stale.status == .limits)
        #expect(stale.freshness == .stale)
        #expect(stale.notice?.severity == .warning)
    }

    @Test func `an unlimited Cursor plan has no limits to show`() {
        let usage = CursorUsage(membershipType: "enterprise", isUnlimited: true, fetchedAt: now)
        let summary = AIUsageSummary.cursor(isConnected: true, usage: usage, problem: nil, isStale: false, now: now)
        #expect(summary.status == .noLimits(title: "Unlimited plan", detail: nil))
    }

    // MARK: Reading

    @Test func `percentages read as used or left, clamped`() {
        let limit = AIUsageLimit(
            id: "x", title: "5-hour", shortTitle: "5h", window: RateLimitWindow(usedPercent: 112), segments: 5)
        #expect(limit.percent(.used) == 100)
        #expect(limit.percent(.remaining) == 0)
        #expect(limit.isUsedUp)
        let partial = AIUsageLimit(
            id: "y", title: "Weekly", shortTitle: "wk", window: RateLimitWindow(usedPercent: 34), segments: 7)
        #expect(partial.percent(.remaining) == 66)
    }
}
