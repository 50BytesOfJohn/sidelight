import Foundation
import Observation
import SidelightCore
import os

/// The account's keys, as far as the key picker has loaded them.
struct OpenRouterKeyList: Equatable {
    var keys: [OpenRouterKey] = []
    /// Where the next page starts; `nil` once every page is loaded.
    var nextOffset: Int? = 0
    var problem: OpenRouterProblem?
    var isLoading = false
    var fetchedAt: Date?
    /// The picker stopped after ``OpenRouterService/maximumKeyPages`` pages: the account may have more keys than it
    /// lists.
    var reachedLimit = false

    /// Whether more keys may be on pages not loaded yet, and can be loaded.
    var hasMore: Bool { nextOffset != nil && fetchedAt != nil && !reachedLimit }
}

/// OpenRouter for every OpenRouter widget and the model catalogue's details panel: the public catalogue, and with a
/// management key saved in Sidelight, the account's balance and spending.
///
/// Each kind of data is a ``RemoteResource`` of its own, fetched once for every widget showing it, as often as the
/// most frequent of them asks and only while one is on screen. Showing models never reads the key; showing the
/// balance never downloads the catalogue. Changing the key forgets everything the old one saw before anything new
/// shows.
///
/// Every request made with the key (balance, spending, the key list) shares one pace: once OpenRouter asks to wait,
/// none is sent before it allows, once it rejects the key, none is sent with it again until a key is saved, and
/// someone's clicks (refresh, more keys) are sent at most once per ``manualActionGap`` between them.
///
/// Removing the key stops its use at once, and for good: the removal is noted outside the keychain before the
/// keychain is asked to delete the key, so a key it couldn't delete isn't used after a restart either. Whether it's
/// still stored is a separate matter: Settings says so, and it stays unused until it's removed or a key is saved
/// again.
@Observable
final class OpenRouterService: DataService {
    /// Sends a request and returns OpenRouter's answer; throws when no answer came back at all.
    typealias Transport = @Sendable (URLRequest) async throws -> HTTP.Response

    /// The key picker loads at most this many pages of keys.
    static let maximumKeyPages = 20
    /// OpenRouter lists keys this many to a page; a shorter page is the last.
    static let keyPageSize = 100
    /// The key picker loads the list again after this long.
    static let keyListLifetime: TimeInterval = 30 * 60
    /// Someone's requests with the key (a refresh, another page of keys) are this far apart at least. The requests of
    /// one click go together.
    static let manualActionGap: Duration = .seconds(15)
    /// Spending is fetched this long after midnight UTC, once the day just ended has been counted.
    static let activityDelay: Duration = .seconds(10 * 60)

    let catalogue: RemoteResource<OpenRouterCatalogue, OpenRouterProblem>
    let balance: RemoteResource<OpenRouterBalance, OpenRouterProblem>
    /// Spending by day, for each scope a chart showed since the key was saved.
    private(set) var activities: [OpenRouterSpendScope: RemoteResource<OpenRouterActivity, OpenRouterProblem>] = [:]
    /// Whether a management key is saved; `nil` until the keychain has been looked at.
    private(set) var hasKey: Bool?
    /// The keychain still holds a key someone removed (it couldn't delete it): it isn't used. Removing it again or
    /// saving a key ends this.
    private(set) var keyRemovalFailed = false
    /// A change to the key that couldn't be noted outside the keychain, so it won't outlast a restart.
    private(set) var unnotedKeyChange: UnnotedKeyChange?
    private(set) var keyList = OpenRouterKeyList()

    /// A change to the key that Sidelight couldn't note outside the keychain.
    enum UnnotedKeyChange: Equatable {
        /// The key was removed but is still in the keychain, and the removal couldn't be noted: once Sidelight
        /// restarts, it uses that key again.
        case removal
        /// A key was saved, but an earlier removal is still noted: once Sidelight restarts, it doesn't use the key
        /// until it's saved again.
        case save
    }

    /// Whether the account can be read now: a key is saved, and isn't one someone removed.
    var canUseKey: Bool { hasKey == true && !keyRemovalFailed }

    /// What the widgets on screen need. Set from the configuration.
    var demand = OpenRouterDemand() {
        didSet {
            guard demand != oldValue else { return }
            apply()
        }
    }

    @ObservationIgnored private let transport: Transport
    @ObservationIgnored private let keyStore: OpenRouterKeyStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var isEnabled = false
    /// Reading the key, once; everything that needs it waits for this one read.
    @ObservationIgnored private var keyLoad: Task<StoredKey, Never>?
    /// The last change to the key: saving it or removing it, in the keychain and in the note of its removal. Each
    /// waits for the one before, so a removal still under way can't delete a key saved after it.
    @ObservationIgnored private var keyOperation: Task<OpenRouterProblem?, Never>?
    /// Counts the saves and removals asked for, so a save that a later one overtook before its turn writes nothing.
    @ObservationIgnored private var keyRequests = 0
    /// Counts the removals asked for: a key saved while one was asked for isn't used.
    @ObservationIgnored private var keyRemovals = 0
    /// Bumped whenever the key changes: an answer fetched with the old key is dropped rather than shown.
    @ObservationIgnored private var keyGeneration = 0
    /// Someone removed the key, and hasn't saved one since: whatever the keychain still holds isn't used.
    @ObservationIgnored private var isKeyWithdrawn = false
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
    ///   - transport: How requests are sent: `HTTP.send`, unless a test stands in for OpenRouter.
    ///   - keyStore: Where the management key and its removal are kept: Sidelight's keychain item, unless a test
    ///     stands in for it.
    ///   - now: The wall clock, for UTC days and ages.
    init(
        transport: @escaping Transport = { try await HTTP.send($0) }, keyStore: OpenRouterKeyStore = .keychain,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.transport = transport
        self.keyStore = keyStore
        self.now = now
        catalogue = RemoteResource(now: now)
        balance = RemoteResource(now: now)
        catalogue.fetch = { [weak self] in await self?.fetchCatalogue() }
        balance.fetch = { [weak self] in await self?.fetchBalance() }
    }

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        apply()
    }

    func stop() {
        isEnabled = false
        apply()
    }

    /// The chart's data for `scope`, once a chart has asked for it.
    func activity(for scope: OpenRouterSpendScope) -> RemoteResource<OpenRouterActivity, OpenRouterProblem>? {
        activities[scope]
    }

    /// Fetches the catalogue now, or as soon as allowed.
    func refreshCatalogue() {
        catalogue.refreshNow()
    }

    /// Fetches the balance now, and the spending for `scope` if a day ended since or it failed: one click, so both
    /// go together. Never sooner than OpenRouter allows or ``manualActionGap`` after the last click's requests, and
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
    /// ``manualActionGap`` after the last one was sent, and once all it fetches would actually be fetched: a resource
    /// can wait longer of its own. Its requests go together. One with nothing left to fetch is dropped.
    private func sendManualRequests() {
        manualRequestWait.cancel()
        pendingRequests.removeAll { delay(of: $0) == nil }
        let gap = pacing.manualWait(gap: Self.manualActionGap)
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

    private func apply() {
        guard isEnabled else {
            catalogue.policy = nil
            balance.policy = nil
            for activity in activities.values { activity.policy = nil }
            // A key picker on screen still needs its keys, even with no widget showing.
            if keyPickers == 0 { stopLoadingKeys() }
            // Refresh clicks have nothing left to fetch, and are dropped.
            sendManualRequests()
            if !demand.keepsAccountData { forgetAccountData() }
            return
        }
        catalogue.policy = demand.catalogue.map(Self.policy)
        balance.policy = demand.balance.map(Self.policy)
        for scope in demand.activity.keys where activities[scope] == nil {
            let activity = RemoteResource<OpenRouterActivity, OpenRouterProblem>(now: now)
            activity.fetch = { [weak self] in await self?.fetchActivity(scope) }
            activities[scope] = activity
        }
        for (scope, activity) in activities {
            activity.policy = demand.activity[scope].map(Self.activityPolicy)
        }
        if !demand.keepsAccountData { forgetAccountData() }
    }

    /// The last Credits widget was removed: what the account showed is forgotten, including work still under way
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

    private static func policy(_ cadence: RefreshCadence) -> RefreshPolicy {
        switch cadence {
        case .manual: .manual
        case .minutes(let minutes): .every(.seconds(minutes * 60))
        }
    }

    /// Spending changes per UTC day, so it's fetched once a day, whatever the balance's interval; a manual widget
    /// fetches it only when asked, like its balance.
    private static func activityPolicy(_ cadence: RefreshCadence) -> RefreshPolicy {
        switch cadence {
        case .manual: .manual
        case .minutes: .dailyUTC(delay: activityDelay)
        }
    }

    // MARK: Fetching

    private func fetchCatalogue() async -> FetchResult<OpenRouterCatalogue, OpenRouterProblem>? {
        let request = OpenRouterAPI.modelsRequest(userAgent: AppInfo.userAgent)
        let answer = await Self.load(request, transport: transport, clock: now) { response, date in
            OpenRouterAPI.catalogue(response, fetchedAt: date)
        }
        guard !Task.isCancelled else { return nil }
        if case .failure(let problem) = answer.result, problem != catalogue.problem {
            Log.openRouter.notice("Can't fetch the model catalogue: \(String(describing: problem), privacy: .public)")
        }
        return FetchResult(answer.result, retry: answer.retry, at: answer.date)
    }

    private func fetchBalance() async -> FetchResult<OpenRouterBalance, OpenRouterProblem>? {
        let generation = keyGeneration
        if let hold = pacing.hold(at: now()) { return .failure(hold.problem, retry: hold.retry) }
        let key = await managementKey()
        guard !Task.isCancelled, generation == keyGeneration else { return nil }
        guard let key else { return .failure(.noKey, retry: .onRequest) }
        // Another request may have been told to wait while the key was read.
        if let hold = pacing.hold(at: now()) { return .failure(hold.problem, retry: hold.retry) }
        let request = OpenRouterAPI.creditsRequest(key: key, userAgent: AppInfo.userAgent)
        let answer = await Self.load(request, transport: transport, clock: now) { response, date in
            OpenRouterAPI.balance(response, fetchedAt: date)
        }
        guard !Task.isCancelled, generation == keyGeneration else { return nil }
        pace(after: answer)
        if case .failure(let problem) = answer.result, problem != balance.problem {
            Log.openRouter.notice("Can't fetch the balance: \(String(describing: problem), privacy: .public)")
        }
        return FetchResult(answer.result, retry: answer.retry, at: answer.date)
    }

    /// Spending for `scope`. A key's is fetched only once OpenRouter confirms the account still has the key: a key
    /// that's gone says so, rather than showing the account's spending instead.
    private func fetchActivity(
        _ scope: OpenRouterSpendScope
    ) async -> FetchResult<OpenRouterActivity, OpenRouterProblem>? {
        let generation = keyGeneration
        if let hold = pacing.hold(at: now()) { return .failure(hold.problem, retry: hold.retry) }
        let key = await managementKey()
        guard !Task.isCancelled, generation == keyGeneration else { return nil }
        guard let key else { return .failure(.noKey, retry: .onRequest) }

        var scopedKey: OpenRouterKey?
        var hash: String?
        if case .key(let keyHash) = scope {
            guard let request = OpenRouterAPI.keyRequest(key: key, hash: keyHash, userAgent: AppInfo.userAgent) else {
                return .failure(.keyNotFound, retry: .onRequest)
            }
            if let hold = pacing.hold(at: now()) { return .failure(hold.problem, retry: hold.retry) }
            let found = await Self.load(request, transport: transport, clock: now) { response, _ in
                OpenRouterAPI.key(response)
            }
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
        let answer = await Self.load(request, transport: transport, clock: now) { response, date in
            OpenRouterAPI.activity(response, key: described, fetchedAt: date)
        }
        guard !Task.isCancelled, generation == keyGeneration else { return nil }
        pace(after: answer)
        if case .failure(let problem) = answer.result {
            Log.openRouter.notice("Can't fetch spending: \(String(describing: problem), privacy: .public)")
        }
        return FetchResult(answer.result, retry: answer.retry, at: answer.date)
    }

    /// What one request came back with, and when.
    private nonisolated struct Answer<Value: Sendable>: Sendable {
        let result: Result<Value, OpenRouterProblem>
        /// When to try again, if it failed.
        let retry: RetryAdvice
        /// When the answer came: what it covers, like the last completed UTC day, is counted from then.
        let date: Date
    }

    /// Sends `request` and reads the answer with `read`, off the main actor: the catalogue is a megabyte of JSON.
    @concurrent
    private static func load<Value: Sendable>(
        _ request: URLRequest, transport: Transport, clock: @Sendable () -> Date,
        read: @Sendable (HTTP.Response, Date) -> Result<Value, OpenRouterProblem>
    ) async -> Answer<Value> {
        let response: HTTP.Response
        do {
            response = try await transport(request)
        } catch {
            return Answer(result: .failure(.unreachable), retry: .backoff, date: clock())
        }
        let date = clock()
        let result = read(response, date)
        switch result {
        case .success:
            return Answer(result: result, retry: .backoff, date: date)
        case .failure(let problem):
            return Answer(
                result: result, retry: OpenRouterAPI.retryAdvice(for: problem, headers: response.headers, now: date),
                date: date)
        }
    }

    /// Notes what OpenRouter said about asking with the key, for every request made with it.
    private func pace<Value: Sendable>(after answer: Answer<Value>) {
        guard case .failure(let problem) = answer.result else { return }
        pacing.record(problem, retry: answer.retry, at: now())
    }

    // MARK: The management key

    /// Looks in the keychain for a saved key, once, so Settings can say whether there is one.
    func lookForKey() {
        guard hasKey == nil, !isKeyWithdrawn else { return }
        Task { _ = await managementKey() }
    }

    /// Checks `candidate` with OpenRouter and saves it in the keychain; returns why it wasn't saved. Only a management
    /// key can read the account's balance and spending.
    ///
    /// Checking it asks OpenRouter once with the candidate itself, whatever the saved key's pace: it's a different
    /// key, and someone just asked. A save cancelled before its turn to be written, or overtaken by a newer save or
    /// removal by then, writes and reports nothing. Once written, it's the keychain's key, but a removal asked for
    /// meanwhile still keeps it from being used. A save that fails changes nothing: a key someone removed stays unused.
    func saveKey(_ candidate: String) async -> OpenRouterProblem? {
        let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .noKey }
        keyRequests += 1
        let request = keyRequests
        let removals = keyRemovals
        if let problem = await checkManagementKey(key) { return problem }
        guard !Task.isCancelled, request == keyRequests else { return nil }
        let store = keyStore
        let operation = queueKeyOperation { [weak self] in
            // Whoever saved it gave up, or a newer save or removal came, before its turn: nothing is written.
            guard let self, !Task.isCancelled, request == keyRequests else { return nil }
            guard await store.save(key) else {
                Log.openRouter.error("Couldn't save the OpenRouter management key in the keychain")
                return .keychain
            }
            // In the keychain now, whoever gave up meanwhile: an earlier removal no longer applies to it.
            let forgotRemoval = await store.removal.note(false)
            if !forgotRemoval {
                Log.openRouter.error("Saved an OpenRouter management key, but couldn't forget an earlier removal")
            }
            // Removed again while it was written: that removal deletes it next, and meanwhile it isn't used.
            guard removals == keyRemovals else { return nil }
            keyLoad = Task { StoredKey.key(key) }
            hasKey = true
            isKeyWithdrawn = false
            keyRemovalFailed = false
            unnotedKeyChange = forgotRemoval ? nil : .save
            keyChanged()
            Log.openRouter.info("Saved an OpenRouter management key")
            return nil
        }
        // Cancelling the save cancels its turn: one not yet written never is. One under way can't be undone.
        return await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    /// Removes the saved key, and everything it showed. Sidelight stops using it right away, whatever happens in
    /// the keychain, and notes the removal before the keychain is asked to delete it, so a key it couldn't delete
    /// isn't used after a restart either. ``keyRemovalFailed`` then says it's still there; only removing it again or
    /// saving a key changes that. What OpenRouter said about the key (a rejection, a wait) still holds meanwhile.
    func removeKey() {
        keyRequests += 1
        keyRemovals += 1
        let removal = keyRemovals
        isKeyWithdrawn = true
        keyLoad = nil
        hasKey = false
        keyRemovalFailed = false
        unnotedKeyChange = nil
        forgetKeyData()
        let store = keyStore
        _ = queueKeyOperation { [weak self] in
            let noted = await store.removal.note(true)
            let deleted = await store.delete()
            // Gone: nothing left to keep from use. Should forgetting the note fail, saving a key forgets it.
            if deleted { _ = await store.removal.note(false) }
            self?.removalFinished(removal, deleted: deleted, noted: noted)
            return nil
        }
    }

    private func removalFinished(_ removal: Int, deleted: Bool, noted: Bool) {
        // Removed again since: that removal shows its own result. A save asked for since comes after this, and
        // shows its own.
        guard removal == keyRemovals else { return }
        guard !deleted else {
            Log.openRouter.info("Removed the OpenRouter management key")
            return
        }
        // Still stored, as far as anyone knows, but not used: it was asked to go.
        keyRemovalFailed = true
        hasKey = true
        if noted {
            Log.openRouter.error("Couldn't remove the OpenRouter management key from the keychain")
        } else {
            unnotedKeyChange = .removal
            Log.openRouter.error(
                "Couldn't remove the OpenRouter management key from the keychain, nor note that it was removed")
        }
    }

    /// Asks OpenRouter whether `key` is a management key, which can read the account.
    private func checkManagementKey(_ key: String) async -> OpenRouterProblem? {
        let request = OpenRouterAPI.currentKeyRequest(key: key, userAgent: AppInfo.userAgent)
        let check = await Self.load(request, transport: transport, clock: now) { response, _ in
            OpenRouterAPI.keyCheck(response)
        }
        guard !Task.isCancelled else { return nil }
        switch check.result {
        case .failure(let problem):
            return problem
        case .success(let check) where check.isManagementKey == true:
            return nil
        case .success(let check) where check.isManagementKey == false:
            return .notManagementKey
        case .success:
            // OpenRouter didn't say: whether it may read the credits settles it.
            let request = OpenRouterAPI.creditsRequest(key: key, userAgent: AppInfo.userAgent)
            let credits = await Self.load(request, transport: transport, clock: now) { response, date in
                OpenRouterAPI.balance(response, fetchedAt: date)
            }
            switch credits.result {
            case .success: return nil
            case .failure(.invalidKey), .failure(.notPermitted): return .notManagementKey
            case .failure(let problem): return problem
            }
        }
    }

    /// A key was saved: everything the old one showed goes before the new one shows anything, and what OpenRouter said
    /// about the old key no longer holds. A key picker on screen lists the keys again, with the new one.
    private func keyChanged() {
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

    /// What the keychain holds, as far as Sidelight may use it.
    private enum StoredKey {
        case key(String)
        case missing
        /// Someone removed the key, and hasn't saved one since: the keychain may still hold it, but it isn't used.
        case removed(isStillStored: Bool)
    }

    /// The key to use: the saved one, read from the keychain the first time; `nil` without one, or once someone
    /// removed it, even if the keychain still holds it, and even if that was before Sidelight last quit.
    private func managementKey() async -> String? {
        guard !isKeyWithdrawn else { return nil }
        let load = keyLoad ?? readStoredKey()
        keyLoad = load
        let stored = await load.value
        // Saved or removed during this read: the newer answer stands.
        guard keyLoad == load else { return await managementKey() }
        switch stored {
        case .key(let key):
            if hasKey != true { hasKey = true }
            return key
        case .missing:
            if hasKey != false { hasKey = false }
            return nil
        case .removed(let isStillStored):
            isKeyWithdrawn = true
            if hasKey != isStillStored { hasKey = isStillStored }
            if keyRemovalFailed != isStillStored { keyRemovalFailed = isStillStored }
            return nil
        }
    }

    private func readStoredKey() -> Task<StoredKey, Never> {
        let store = keyStore
        return Task {
            // A removal is noted: the keychain is only asked whether it still holds the key, to say so.
            if await store.removal.isNoted() { return .removed(isStillStored: await store.read() != nil) }
            return await store.read().map(StoredKey.key) ?? .missing
        }
    }

    /// Queues `operation` on the key, to run once the one before it is done: the key and the note of its removal
    /// change one operation at a time, in the order asked. Cancelling the task it returns cancels the operation;
    /// it checks for that before it changes anything.
    private func queueKeyOperation(
        _ operation: @escaping @MainActor () async -> OpenRouterProblem?
    ) -> Task<OpenRouterProblem?, Never> {
        let previous = keyOperation
        let task = Task {
            _ = await previous?.value
            return await operation()
        }
        keyOperation = task
        return task
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
        if let fetchedAt = keyList.fetchedAt, now().timeIntervalSince(fetchedAt) < Self.keyListLifetime { return }
        guard !keyList.isLoading, keyList.problem == nil || keyList.fetchedAt != nil else { return }
        forgetKeyList()
        loadNextKeyPage()
    }

    /// Loads the next page of keys, up to ``maximumKeyPages`` pages: someone's click, so paced like a refresh.
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
        let key = await managementKey()
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
        let answer = await Self.load(request, transport: transport, clock: now) { response, _ in
            OpenRouterAPI.keyPage(response)
        }
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
            keyList.nextOffset = page.entryCount >= Self.keyPageSize ? next : nil
            keyList.reachedLimit = keyList.nextOffset != nil && next >= Self.keyPageSize * Self.maximumKeyPages
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
