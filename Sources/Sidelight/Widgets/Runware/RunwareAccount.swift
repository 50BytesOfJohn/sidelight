import Foundation
import Observation
import SidelightCore
import os

/// One Runware account, as its key reads it: the organization's details (balance, rolling usage, keys), its 30-day
/// activity, and on request a day's models or a page of the model catalogue. Every widget using the account, and
/// the details panel, share it.
///
/// Every request made with the key shares one pace: once Runware asks to wait, none is sent before it allows; once it
/// rejects the key, none is sent with it again until the key is replaced; and someone's clicks are sent at most once
/// per ``RunwareService/manualActionGap``. The key itself is the account store's, or the CLI's: this only reads it,
/// and starts over when it's replaced.
@Observable
final class RunwareAccount {
    /// What loading one day's models has come to.
    enum DayModelsState: Equatable {
        case loading
        case loaded(RunwareDayModels)
        case failed(RunwareProblem)
    }

    /// Today's models are fetched again once they're this old.
    static let todayLifetime: TimeInterval = 5 * 60
    /// The details panel fetches the activity again on opening once it's this old.
    static let activityLifetimeOnOpen: TimeInterval = 5 * 60
    /// At most this many days' models are kept.
    static let maximumDays = RunwareActivity.windowDays + 1

    let id: AccountID
    let details: RemoteResource<RunwareAccountDetails, RunwareProblem>
    let activity: RemoteResource<RunwareActivity, RunwareProblem>
    /// The days whose models the History tab opened.
    private(set) var dayModels: [UTCDay: DayModelsState] = [:]

    @ObservationIgnored private let client: RunwareClient
    @ObservationIgnored private let credentials: () async -> Result<String, RunwareProblem>
    @ObservationIgnored private let report: (AccountStatus?) -> Void
    @ObservationIgnored private let reportIdentity: (String?) -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let manualActionGap: Duration
    @ObservationIgnored private var demand = RunwareAccountDemand()
    @ObservationIgnored private var isKept = false
    @ObservationIgnored private var isEnabled = false
    /// Bumped whenever the key changes: an answer fetched with the old key is dropped rather than shown, and what the
    /// details panel found with it goes.
    private(set) var keyGeneration = 0
    @ObservationIgnored private var pacing = RunwareAccount.newPacing()
    @ObservationIgnored private var dayModelTasks: [UTCDay: Task<Void, Never>] = [:]
    /// A click waiting for its turn: whether it fetches the activity too.
    @ObservationIgnored private var pendingRefresh: Bool?
    @ObservationIgnored private let manualRequestWait = DelayedTask()

    /// - Parameters:
    ///   - credentials: The key to ask with, or why there's none.
    ///   - report: Says how the account is doing, after each answer from Runware.
    ///   - reportIdentity: Says which organization the key belongs to.
    init(
        id: AccountID, client: RunwareClient, credentials: @escaping () async -> Result<String, RunwareProblem>,
        report: @escaping (AccountStatus?) -> Void = { _ in }, reportIdentity: @escaping (String?) -> Void = { _ in },
        manualActionGap: Duration
    ) {
        self.id = id
        self.client = client
        self.credentials = credentials
        self.report = report
        self.reportIdentity = reportIdentity
        self.manualActionGap = manualActionGap
        now = client.now
        details = RemoteResource(now: client.now)
        activity = RemoteResource(now: client.now)
        details.fetch = { [weak self] in await self?.fetchDetails() }
        activity.fetch = { [weak self] in await self?.fetchActivity() }
    }

    /// Runware rejected the key (401), or what it may read (403): asking again with it can't help.
    private static func newPacing() -> AccountPacing<RunwareProblem> {
        AccountPacing(rateLimited: .rateLimited) { $0 == .invalidKey || $0 == .notPermitted }
    }

    // MARK: Demand

    /// Fetches what `demand` asks for while `isEnabled`; `isKept` keeps what it showed while nothing does.
    func update(demand: RunwareAccountDemand, isKept: Bool, isEnabled: Bool) {
        guard demand != self.demand || isKept != self.isKept || isEnabled != self.isEnabled else { return }
        self.demand = demand
        self.isKept = isKept
        self.isEnabled = isEnabled
        if isEnabled {
            details.policy = demand.details.map { RefreshPolicy($0) }
            activity.policy = demand.activity.map { RefreshPolicy(activityAt: $0) }
        } else {
            details.policy = nil
            activity.policy = nil
            cancelDayModelLoads()
        }
        // Clicks with nothing left to fetch are dropped.
        sendPendingRefresh()
        if !isKept { forgetData() }
    }

    /// Fetches the details now, and the activity too if `includingActivity`: one click, so they go together. Never
    /// sooner than Runware allows or the gap between clicks, and not at all with a key it rejected.
    func refresh(includingActivity: Bool) {
        pendingRefresh = (pendingRefresh ?? false) || includingActivity
        sendPendingRefresh()
    }

    /// The details panel opened: the activity is fetched again if it's more than a few minutes old.
    func refreshActivityIfStale() {
        guard let fetchedAt = activity.fetchedAt else { return }
        if now().timeIntervalSince(fetchedAt) > Self.activityLifetimeOnOpen
            || activity.value?.isBehind(at: now()) == true
        {
            activity.refreshNow()
        }
    }

    private func sendPendingRefresh() {
        manualRequestWait.cancel()
        guard let includingActivity = pendingRefresh else { return }
        let delays = [details.refreshDelay, includingActivity ? activity.refreshDelay : nil].compactMap(\.self)
        guard let delay = delays.max() else {
            pendingRefresh = nil
            return
        }
        let wait = max(delay, pacing.manualWait(gap: manualActionGap))
        guard wait <= .zero else {
            manualRequestWait.schedule(after: wait) { [weak self] in self?.sendPendingRefresh() }
            return
        }
        pendingRefresh = nil
        details.refreshNow()
        if includingActivity { activity.refreshNow() }
        pacing.manualRequestSent()
    }

    /// No widget uses this account any more: what it showed goes, including work under way and failures.
    private func forgetData() {
        pendingRefresh = nil
        manualRequestWait.cancel()
        cancelDayModelLoads()
        if !dayModels.isEmpty { dayModels = [:] }
        if details.value != nil || details.problem != nil || details.isFetching { details.reset() }
        if activity.value != nil || activity.problem != nil || activity.isFetching { activity.reset() }
    }

    // MARK: The key

    /// The account's key was replaced, or the CLI signed in with another: everything the old one showed goes before
    /// the new one shows anything, and what Runware said about the old key no longer holds.
    func keyChanged() {
        keyGeneration += 1
        pacing = Self.newPacing()
        pendingRefresh = nil
        manualRequestWait.cancel()
        cancelDayModelLoads()
        dayModels = [:]
        reportIdentity(nil)
        details.reset()
        activity.reset()
    }

    // MARK: Fetching

    private func fetchDetails() async -> FetchResult<RunwareAccountDetails, RunwareProblem>? {
        let uuid = UUID()
        guard
            let answer = await send(
                { RunwareAPI.detailsRequest(key: $0, taskUUID: uuid, userAgent: AppInfo.userAgent) },
                read: { RunwareAPI.details($0, taskUUID: uuid, fetchedAt: $1) })
        else { return nil }
        switch answer.result {
        case .success(let value):
            report(.connected)
            reportIdentity(value.organizationName)
        case .failure(let problem) where problem != details.problem:
            Log.runware.notice("Can't fetch the account: \(String(describing: problem), privacy: .public)")
        case .failure:
            break
        }
        return answer.fetchResult
    }

    private func fetchActivity() async -> FetchResult<RunwareActivity, RunwareProblem>? {
        let uuid = UUID()
        let window = RunwareActivity.window(endingAt: now())
        guard
            let answer = await send(
                {
                    RunwareAPI.activityRequest(
                        key: $0, window: window, groupBy: [.date, .model], taskUUID: uuid, userAgent: AppInfo.userAgent)
                },
                read: { RunwareAPI.activity($0, taskUUID: uuid, window: window, fetchedAt: $1) })
        else { return nil }
        if case .failure(let problem) = answer.result, problem != activity.problem {
            Log.runware.notice("Can't fetch usage activity: \(String(describing: problem), privacy: .public)")
        }
        return answer.fetchResult
    }

    /// `day`'s models straight from the current activity, when it breaks models down by day and covers `day`. Read
    /// live rather than copied, so they follow every refresh of the activity.
    func activityDayModels(_ day: UTCDay) -> RunwareDayModels? {
        guard let activity = activity.value, activity.modelsByDay != nil, activity.window.contains(day) else {
            return nil
        }
        return RunwareDayModels(day: day, activity: activity)
    }

    /// Loads `day`'s models for the History tab with a request of its own, unless the activity already has them. A
    /// completed day is loaded once; today again once it's a few minutes old.
    func loadDayModels(_ day: UTCDay) {
        if activityDayModels(day) != nil { return }
        switch dayModels[day] {
        case .loading:
            return
        case .loaded(let loaded)
        where day < UTCDay(now()) || now().timeIntervalSince(loaded.fetchedAt) < Self.todayLifetime:
            return
        default:
            break
        }
        dayModels[day] = .loading
        trimDays()
        let generation = keyGeneration
        dayModelTasks[day] = Task { [weak self] in
            guard let self else { return }
            let uuid = UUID()
            let answer = await send(
                {
                    RunwareAPI.activityRequest(
                        key: $0, window: day...day, groupBy: [.model], taskUUID: uuid, userAgent: AppInfo.userAgent)
                },
                read: { RunwareAPI.activity($0, taskUUID: uuid, window: day...day, fetchedAt: $1) })
            guard !Task.isCancelled, generation == keyGeneration, let answer else { return }
            dayModelTasks[day] = nil
            switch answer.result {
            case .success(let activity): dayModels[day] = .loaded(RunwareDayModels(day: day, activity: activity))
            case .failure(let problem): dayModels[day] = .failed(problem)
            }
        }
    }

    /// Stops loading days' models, forgetting those still loading.
    func cancelDayModelLoads() {
        for task in dayModelTasks.values { task.cancel() }
        dayModelTasks = [:]
        let loading = dayModels.filter { $0.value == .loading }.keys
        for day in loading { dayModels[day] = nil }
    }

    /// Keeps the most recent days only.
    private func trimDays() {
        guard dayModels.count > Self.maximumDays else { return }
        for day in dayModels.keys.sorted().prefix(dayModels.count - Self.maximumDays) {
            dayModelTasks[day]?.cancel()
            dayModelTasks[day] = nil
            dayModels[day] = nil
        }
    }

    /// One page of the model catalogue; `nil` when the key changed meanwhile or the caller was cancelled. The caller
    /// owns debouncing and cancelling; nothing is cached here.
    func searchModels(_ query: RunwareModelQuery) async -> Result<RunwareModelPage, RunwareProblem>? {
        let uuid = UUID()
        let answer = await send(
            { RunwareAPI.modelSearchRequest(key: $0, query: query, taskUUID: uuid, userAgent: AppInfo.userAgent) },
            read: { response, _ in RunwareAPI.modelPage(response, taskUUID: uuid, query: query) })
        return answer?.result
    }

    /// Reads the key, then sends the request `build` makes with it and reads the answer with `read`, unless Runware
    /// asked to wait or rejected the key. `nil` once cancelled, or when the key changed meanwhile.
    private func send<Value: Sendable>(
        _ build: (String) -> URLRequest,
        read: @escaping @Sendable (HTTP.Response, Date) -> Result<Value, RunwareProblem>
    ) async -> RunwareClient.Answer<Value>? {
        let generation = keyGeneration
        if let hold = pacing.hold(at: now()) {
            return RunwareClient.Answer(result: .failure(hold.problem), retry: hold.retry, date: now())
        }
        let key = await credentials()
        guard !Task.isCancelled, generation == keyGeneration else { return nil }
        switch key {
        case .failure(let problem):
            if let status = problem.accountStatus { report(status) }
            return RunwareClient.Answer(
                result: .failure(problem), retry: RunwareAPI.retryAdvice(for: problem, now: now()), date: now())
        case .success(let key):
            // Another request may have been told to wait while the key was read.
            if let hold = pacing.hold(at: now()) {
                return RunwareClient.Answer(result: .failure(hold.problem), retry: hold.retry, date: now())
            }
            let answer = await client.send(build(key), read: read)
            guard !Task.isCancelled, generation == keyGeneration else { return nil }
            if case .failure(let problem) = answer.result {
                pacing.record(problem, retry: answer.retry, at: now())
                if let status = problem.accountStatus { report(status) }
            }
            return answer
        }
    }
}

extension RefreshPolicy {
    /// The activity changes slowly and costs more to ask for, so it's fetched at most every
    /// ``RunwareSettings/activityMinimumMinutes``, whatever the widget's `cadence`; a manual widget fetches it only when
    /// asked.
    init(activityAt cadence: RefreshCadence) {
        switch cadence {
        case .manual: self = .manual
        case .minutes(let minutes):
            self = .every(.seconds(max(minutes, RunwareSettings.activityMinimumMinutes) * 60))
        }
    }
}
