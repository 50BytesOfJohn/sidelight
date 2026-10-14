import Foundation
import Observation
import SidelightCore
import os

/// One OpenRouter account, as its management key reads it: the balance, spending by day, and the key list for a
/// chart's key picker. Every Balance block that uses the account shares it.
///
/// Every request made with the key (balance, spending, the key list) shares one pace: once OpenRouter asks to wait,
/// none is sent before it allows, once it rejects the key, none is sent with it again until the key is replaced, and
/// someone's clicks (refresh, more keys) are sent at most once per ``OpenRouterService/manualActionGap`` between
/// them. The key itself is the account store's: this only reads it, and starts over when it's replaced or removed.
@Observable
final class OpenRouterAccount {
    let id: AccountID
    let balance: RemoteResource<OpenRouterBalance, OpenRouterProblem>
    /// Spending by day, for each scope a chart showed since the key was saved.
    private(set) var activities: [OpenRouterSpendScope: RemoteResource<OpenRouterActivity, OpenRouterProblem>] = [:]
    /// Whether the account has a key; `nil` until it's been read.
    private(set) var hasKey: Bool?
    private(set) var keyList = OpenRouterKeyList()

    /// Whether the account can be read now: it has a key.
    var canUseKey: Bool { hasKey == true }

    @ObservationIgnored private let client: OpenRouterClient
    @ObservationIgnored private let secret: () async throws(KeychainUnavailable) -> String?
    @ObservationIgnored private let report: (AccountStatus?) -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Someone's clicks are this far apart at least.
    @ObservationIgnored private let manualActionGap: Duration
    @ObservationIgnored private var demand = OpenRouterAccountDemand()
    /// A Balance block reads this account, shown or not: what it showed is worth keeping.
    @ObservationIgnored private var isKept = false
    @ObservationIgnored private var isEnabled = false
    /// Bumped whenever the key changes: an answer fetched with the old key is dropped rather than shown.
    @ObservationIgnored private var keyGeneration = 0
    /// What OpenRouter said about asking with the current key, for every request made with it.
    @ObservationIgnored private var pacing = AccountPacing()
    @ObservationIgnored private var keyListTask: Task<Void, Never>?
    /// Bumped whenever loading keys stops: a page still loading then is dropped.
    @ObservationIgnored private var keyListGeneration = 0
    /// Key pickers on screen. Pages of keys load for them only: once none is left, loading stops.
    @ObservationIgnored private var keyPickers = 0
    /// Clicks waiting for their turn, at most one of each.
    @ObservationIgnored private var pendingRequests: [ManualRequest] = []
    @ObservationIgnored private let manualRequestWait = DelayedTask()

    /// - Parameters:
    ///   - secret: Reads the account's key; `nil` when it has none, throwing when the keychain can't say.
    ///   - report: Says how the account is doing, after each answer from OpenRouter.
    init(
        id: AccountID, client: OpenRouterClient, secret: @escaping () async throws(KeychainUnavailable) -> String?,
        report: @escaping (AccountStatus?) -> Void = { _ in }, manualActionGap: Duration
    ) {
        self.id = id
        self.client = client
        self.secret = secret
        self.report = report
        self.manualActionGap = manualActionGap
        now = client.now
        balance = RemoteResource(now: client.now)
        balance.fetch = { [weak self] in await self?.fetchBalance() }
    }

    /// The chart's data for `scope`, once a chart has asked for it.
    func activity(for scope: OpenRouterSpendScope) -> RemoteResource<OpenRouterActivity, OpenRouterProblem>? {
        activities[scope]
    }

    /// Fetches the balance now, and the spending for `scope` if a day ended since or it failed: one click, so both
    /// go together. Never sooner than OpenRouter allows or the gap between clicks after the last click's requests, and
    /// not at all with a key it rejected.
    func refreshAccount(scope: OpenRouterSpendScope?) {
        queue(.account(scope))
    }

    /// Someone's click that asks OpenRouter with the key.
    private enum ManualRequest: Equatable {
        /// The balance, and the spending for a scope if it's due.
        case account(OpenRouterSpendScope?)
        /// The next page of keys; the first again if it failed.
        case keys
    }

    /// Sends `request` once it may go, unless the same one is already waiting.
    private func queue(_ request: ManualRequest) {
        if !pendingRequests.contains(request) { pendingRequests.append(request) }
        sendManualRequests()
    }

    /// Sends the waiting click that can go soonest, if it can go now, and otherwise waits until it can. A click goes
    /// the gap between clicks after the last one was sent, and once all it fetches would actually be fetched: a resource
    /// can wait longer of its own. Its requests go together. One with nothing left to fetch is dropped.
    private func sendManualRequests() {
        manualRequestWait.cancel()
        pendingRequests.removeAll { delay(of: $0) == nil }
        let gap = pacing.manualWait(gap: manualActionGap)
        let waits = pendingRequests.map { max(gap, delay(of: $0) ?? .zero) }
        guard let wait = waits.min(), let index = waits.firstIndex(of: wait) else { return }
        guard wait <= .zero else {
            // Checked again then: a click may have gone meanwhile, or what it fetches may have changed.
            manualRequestWait.schedule(after: wait) { [weak self] in self?.sendManualRequests() }
            return
        }
        send(pendingRequests.remove(at: index))
        pacing.manualRequestSent()
        sendManualRequests()
    }

    /// How long until everything `request` fetches can be fetched; `nil` when there's nothing left to fetch.
    private func delay(of request: ManualRequest) -> Duration? {
        switch request {
        case .account(let scope):
            [balance.refreshDelay, scope.flatMap(dueActivity)?.refreshDelay].compactMap(\.self).max()
        case .keys:
            keyList.isLoading ? nil : .zero
        }
    }

    private func send(_ request: ManualRequest) {
        switch request {
        case .account(let scope):
            balance.refreshNow()
            scope.flatMap(dueActivity)?.refreshNow()
        case .keys:
            // Not even the first page loaded: start over, its failure forgotten.
            if keyList.fetchedAt == nil { forgetKeyList() }
            loadNextKeyPage()
        }
    }

    /// The spending for `scope`, when a click should fetch it: a day ended since it was fetched, or it failed.
    private func dueActivity(_ scope: OpenRouterSpendScope) -> RemoteResource<OpenRouterActivity, OpenRouterProblem>? {
        guard let activity = activities[scope],
            activity.problem != nil || activity.value.map({ $0.isBehind(at: now()) }) ?? true
        else { return nil }
        return activity
    }

    /// Drops clicks still waiting: the key or the account's data they were for is gone.
    private func dropManualRequests() {
        pendingRequests = []
        manualRequestWait.cancel()
    }

    // MARK: Demand

    /// Fetches what `demand` asks for while `isEnabled`; `isKept` keeps what it showed while nothing does.
    func update(demand: OpenRouterAccountDemand, isKept: Bool, isEnabled: Bool) {
        guard demand != self.demand || isKept != self.isKept || isEnabled != self.isEnabled else { return }
        self.demand = demand
        self.isKept = isKept
        self.isEnabled = isEnabled
        apply()
    }

    private func apply() {
        guard isEnabled else {
            balance.policy = nil
            for activity in activities.values { activity.policy = nil }
            // A key picker on screen still needs its keys, even with no widget showing.
            if keyPickers == 0 { stopLoadingKeys() }
            // Refresh clicks have nothing left to fetch, and are dropped.
            sendManualRequests()
            if !isKept { forgetAccountData() }
            return
        }
        balance.policy = demand.balance.map { RefreshPolicy($0) }
        for scope in demand.activity.keys where activities[scope] == nil {
            let activity = RemoteResource<OpenRouterActivity, OpenRouterProblem>(now: now)
            activity.fetch = { [weak self] in await self?.fetchActivity(scope) }
            activities[scope] = activity
        }
        for (scope, activity) in activities {
            activity.policy = demand.activity[scope].map { RefreshPolicy(spendingAt: $0) }
        }
        if !isKept { forgetAccountData() }
    }

    /// No Balance block reads this account any more: what it showed is forgotten, including work still under way
    /// and failures, whether or not anything was ever fetched. The key stays saved. Safe to call any number of times.
    private func forgetAccountData() {
        forgetKeyList()
        dropManualRequests()
        if balance.value != nil || balance.problem != nil || balance.isFetching { balance.reset() }
        if !activities.isEmpty {
            for activity in activities.values { activity.policy = nil }
            activities = [:]
        }
    }

    /// Stops loading keys and forgets the list, its failures included: a page still loading is dropped.
    private func forgetKeyList() {
        keyListTask?.cancel()
        keyListTask = nil
        keyListGeneration += 1
        if keyList != OpenRouterKeyList() { keyList = OpenRouterKeyList() }
    }

    /// Stops loading keys, dropping a page still loading and clicks for more; the keys loaded so far stay.
    private func stopLoadingKeys() {
        keyListTask?.cancel()
        keyListTask = nil
        keyListGeneration += 1
        if keyList.isLoading { keyList.isLoading = false }
        if pendingRequests.contains(.keys) {
            pendingRequests.removeAll { $0 == .keys }
            sendManualRequests()
        }
    }

    // MARK: Fetching

    private func fetchBalance() async -> FetchResult<OpenRouterBalance, OpenRouterProblem>? {
        let generation = keyGeneration
        if let hold = pacing.hold(at: now()) { return .failure(hold.problem, retry: hold.retry) }
        let key: String?
        do throws(KeychainUnavailable) {
            key = try await managementKey()
        } catch {
            return Task.isCancelled || generation != keyGeneration ? nil : .failure(.keychain, retry: .backoff)
        }
        guard !Task.isCancelled, generation == keyGeneration else { return nil }
        guard let key else { return .failure(.noKey, retry: .onRequest) }
        // Another request may have been told to wait while the key was read.
        if let hold = pacing.hold(at: now()) { return .failure(hold.problem, retry: hold.retry) }
        let answer = await client.send(OpenRouterAPI.creditsRequest(key: key, userAgent: AppInfo.userAgent)) {
            OpenRouterAPI.balance($0, fetchedAt: $1)
        }
        guard !Task.isCancelled, generation == keyGeneration else { return nil }
        pace(after: answer)
        if case .success = answer.result { report(.connected) }
        if case .failure(let problem) = answer.result, problem != balance.problem {
            Log.openRouter.notice("Can't fetch the balance: \(String(describing: problem), privacy: .public)")
        }
        return answer.fetchResult
    }

    /// Spending for `scope`. A key's is fetched only once OpenRouter confirms the account still has the key: a key
    /// that's gone says so, rather than showing the account's spending instead.
    private func fetchActivity(
        _ scope: OpenRouterSpendScope
    ) async -> FetchResult<OpenRouterActivity, OpenRouterProblem>? {
        let generation = keyGeneration
        if let hold = pacing.hold(at: now()) { return .failure(hold.problem, retry: hold.retry) }
        let key: String?
        do throws(KeychainUnavailable) {
            key = try await managementKey()
        } catch {
            return Task.isCancelled || generation != keyGeneration ? nil : .failure(.keychain, retry: .backoff)
        }
        guard !Task.isCancelled, generation == keyGeneration else { return nil }
        guard let key else { return .failure(.noKey, retry: .onRequest) }

        var scopedKey: OpenRouterKey?
        var hash: String?
        if case .key(let keyHash) = scope {
            guard let request = OpenRouterAPI.keyRequest(key: key, hash: keyHash, userAgent: AppInfo.userAgent) else {
                return .failure(.keyNotFound, retry: .onRequest)
            }
            if let hold = pacing.hold(at: now()) { return .failure(hold.problem, retry: hold.retry) }
            let found = await client.send(request) { response, _ in OpenRouterAPI.key(response) }
            guard !Task.isCancelled, generation == keyGeneration else { return nil }
            pace(after: found)
            switch found.result {
            case .success(let found): scopedKey = found
            case .failure(let problem): return .failure(problem, retry: found.retry)
            }
            hash = keyHash
        }

        if let hold = pacing.hold(at: now()) { return .failure(hold.problem, retry: hold.retry) }
        let request = OpenRouterAPI.activityRequest(key: key, keyHash: hash, userAgent: AppInfo.userAgent)
        let described = scopedKey
        let answer = await client.send(request) { response, date in
            OpenRouterAPI.activity(response, key: described, fetchedAt: date)
        }
        guard !Task.isCancelled, generation == keyGeneration else { return nil }
        pace(after: answer)
        if case .failure(let problem) = answer.result {
            Log.openRouter.notice("Can't fetch spending: \(String(describing: problem), privacy: .public)")
        }
        return answer.fetchResult
    }

    /// Notes what OpenRouter said about asking with the key, for every request made with it, and how the account is
    /// doing when that's a problem with the account.
    private func pace<Value: Sendable>(after answer: OpenRouterClient.Answer<Value>) {
        guard case .failure(let problem) = answer.result else { return }
        pacing.record(problem, retry: answer.retry, at: now())
        if let status = problem.accountStatus { report(status) }
    }

    // MARK: The management key

    /// The account's key was replaced or removed: everything the old one showed goes before the new one shows
    /// anything, and what OpenRouter said about the old key no longer holds. A key picker on screen lists the keys
    /// again, with the new one.
    func keyChanged() {
        hasKey = nil
        pacing = AccountPacing()
        forgetKeyData()
        if keyPickers > 0 { loadNextKeyPage() }
    }

    /// Everything the key showed goes, and answers still on their way are dropped. Resources still needed fetch
    /// again, with whatever key is in use now.
    private func forgetKeyData() {
        keyGeneration += 1
        forgetKeyList()
        dropManualRequests()
        balance.reset()
        for activity in activities.values { activity.reset() }
    }

    /// The account's key, read through the account store's keyring (which reads the keychain once); `nil` without
    /// one, which the account then reports. Throws when the keychain can't say now: that's not a missing key.
    private func managementKey() async throws(KeychainUnavailable) -> String? {
        let key = try await secret()
        if hasKey != (key != nil) { hasKey = key != nil }
        if key == nil { report(.needsSignIn) }
        return key
    }

    // MARK: Key picker

    /// A key picker appeared: it loads the first page of keys, unless it was loaded lately, and keeps loading keys
    /// until the last picker disappears.
    func keyPickerAppeared() {
        keyPickers += 1
        loadKeysIfNeeded()
    }

    /// A key picker disappeared. With none left, a page still loading is dropped, and so are clicks for more; the
    /// keys loaded so far stay.
    func keyPickerDisappeared() {
        keyPickers = max(0, keyPickers - 1)
        if keyPickers == 0 { stopLoadingKeys() }
    }

    /// Loads the first page of keys as the picker appears, unless it was loaded lately. After a failure, only
    /// ``retryKeys()`` tries again, so showing the picker again doesn't.
    func loadKeysIfNeeded() {
        if let fetchedAt = keyList.fetchedAt, now().timeIntervalSince(fetchedAt) < OpenRouterService.keyListLifetime {
            return
        }
        guard !keyList.isLoading, keyList.problem == nil || keyList.fetchedAt != nil else { return }
        forgetKeyList()
        loadNextKeyPage()
    }

    /// Loads the next page of keys, up to ``OpenRouterService/maximumKeyPages`` pages: someone's click, so paced like a refresh.
    func loadMoreKeys() {
        queue(.keys)
    }

    /// Loads the keys again after they failed, or before any loaded: the first page, or the one that failed.
    func retryKeys() {
        queue(.keys)
    }

    private func loadNextKeyPage() {
        guard !keyList.isLoading, !keyList.reachedLimit, let offset = keyList.nextOffset else { return }
        if let hold = pacing.hold(at: now()) {
            keyList.problem = hold.problem
            return
        }
        keyList.isLoading = true
        let generation = keyGeneration
        let listGeneration = keyListGeneration
        keyListTask = Task { [weak self] in
            await self?.loadKeys(from: offset, generation: generation, listGeneration: listGeneration)
        }
    }

    private func loadKeys(from offset: Int, generation: Int, listGeneration: Int) async {
        func isCurrent() -> Bool {
            !Task.isCancelled && generation == keyGeneration && listGeneration == keyListGeneration
        }
        let key: String?
        do throws(KeychainUnavailable) {
            key = try await managementKey()
        } catch {
            guard isCurrent() else { return }
            keyList.isLoading = false
            keyList.problem = .keychain
            return
        }
        guard isCurrent() else { return }
        guard let key else {
            keyList.isLoading = false
            keyList.problem = .noKey
            return
        }
        // Another request may have been told to wait, or had the key rejected, while the key was read.
        if let hold = pacing.hold(at: now()) {
            keyList.isLoading = false
            keyList.problem = hold.problem
            return
        }
        let request = OpenRouterAPI.keysRequest(key: key, offset: offset, userAgent: AppInfo.userAgent)
        let answer = await client.send(request) { response, _ in OpenRouterAPI.keyPage(response) }
        guard isCurrent() else { return }
        pace(after: answer)
        keyList.isLoading = false
        switch answer.result {
        case .success(let page):
            // Keys created or deleted between pages can shift them: keep the first of any repeat. Where the next page
            // starts goes by what OpenRouter listed, readable or not.
            let known = Set(keyList.keys.map(\.hash))
            keyList.keys += page.keys.filter { !known.contains($0.hash) }
            let next = offset + page.entryCount
            keyList.nextOffset = page.entryCount >= OpenRouterService.keyPageSize ? next : nil
            keyList.reachedLimit =
                keyList.nextOffset != nil && next >= OpenRouterService.keyPageSize * OpenRouterService.maximumKeyPages
            keyList.problem = nil
            if offset == 0 { keyList.fetchedAt = answer.date }
        case .failure(let problem):
            keyList.problem = problem
        }
    }
}

/// What OpenRouter said about asking with one key, whatever was asked: when it allows the next request, and whether
/// it rejected the key; and when someone's click last sent requests. Forgotten when a key is saved.
private struct AccountPacing {
    /// OpenRouter asked not to be asked again before this.
    private var notBefore: ContinuousClock.Instant?
    /// OpenRouter rejected the key (401), or what it may read (403): asking again with it can't help.
    private var rejection: OpenRouterProblem?
    /// When someone's last refresh or page of keys was sent.
    private var lastManualRequest: ContinuousClock.Instant?

    /// How long until someone's next click may send requests, `gap` after their last one did.
    func manualWait(gap: Duration) -> Duration {
        guard let lastManualRequest else { return .zero }
        return max(.zero, lastManualRequest + gap - .now)
    }

    mutating func manualRequestSent() {
        lastManualRequest = .now
    }

    mutating func record(_ problem: OpenRouterProblem, retry: RetryAdvice, at now: Date) {
        switch problem {
        case .invalidKey, .notPermitted: rejection = problem
        default: break
        }
        if case .notBefore(let date) = retry {
            let instant = ContinuousClock.now + .seconds(max(0, date.timeIntervalSince(now)))
            notBefore = max(notBefore ?? instant, instant)
        }
    }

    /// Why a request mustn't be sent at `now`, and when one may be; `nil` to go ahead.
    func hold(at now: Date) -> (problem: OpenRouterProblem, retry: RetryAdvice)? {
        if let rejection { return (rejection, .onRequest) }
        guard let notBefore, notBefore > .now else { return nil }
        return (.rateLimited, .notBefore(now.addingTimeInterval((notBefore - .now).timeInterval)))
    }
}

extension RefreshPolicy {
    /// Spending changes per UTC day, so it's fetched once a day, whatever the balance's `cadence`; a manual widget
    /// fetches it only when asked, like its balance.
    init(spendingAt cadence: RefreshCadence) {
        switch cadence {
        case .manual: self = .manual
        case .minutes: self = .dailyUTC(delay: OpenRouterService.activityDelay)
        }
    }
}
