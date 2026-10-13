import Foundation
import Observation
import SidelightCore
import os

/// The account's keys, as far as the key picker has loaded them.
struct OpenRouterKeyList {
    var keys: [OpenRouterKey] = []
    /// Where the next page starts; `nil` once every page is loaded.
    var nextOffset: Int? = 0
    var problem: OpenRouterProblem?
    var isLoading = false
    var fetchedAt: Date?

    /// Whether more keys may be on pages not loaded yet.
    var hasMore: Bool { nextOffset != nil && fetchedAt != nil }
}

/// OpenRouter for every OpenRouter widget and the model catalogue's details panel: the public catalogue, and with a
/// management key saved in Sidelight, the account's balance and spending.
///
/// Each kind of data is a ``RemoteResource`` of its own, fetched once for every widget showing it, as often as the
/// most frequent of them asks and only while one is on screen. Showing models never reads the key; showing the
/// balance never downloads the catalogue. Changing the key forgets everything the old one saw before anything new
/// shows.
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
    /// Spending is fetched this long after midnight UTC, once the day just ended has been counted.
    static let activityDelay: Duration = .seconds(10 * 60)

    let catalogue = RemoteResource<OpenRouterCatalogue, OpenRouterProblem>()
    let balance = RemoteResource<OpenRouterBalance, OpenRouterProblem>()
    /// Spending by day, for each scope a chart showed since the key was saved.
    private(set) var activities: [OpenRouterSpendScope: RemoteResource<OpenRouterActivity, OpenRouterProblem>] = [:]
    /// Whether a management key is saved; `nil` until the keychain has been looked at.
    private(set) var hasKey: Bool?
    private(set) var keyList = OpenRouterKeyList()

    /// What the widgets on screen need. Set from the configuration.
    var demand = OpenRouterDemand() {
        didSet {
            guard demand != oldValue else { return }
            apply()
        }
    }

    @ObservationIgnored private let transport: Transport
    @ObservationIgnored private let keyStore: OpenRouterKeyStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var isEnabled = false
    /// Reading the key, once; everything that needs it waits for this one read.
    @ObservationIgnored private var keyLoad: Task<String?, Never>?
    /// The last change to the keychain item. Each waits for the one before, so a removal still under way can't
    /// delete a key saved after it.
    @ObservationIgnored private var keyWrite: Task<Bool, Never>?
    /// Counts saves and removals, so a save that a later one overtook while OpenRouter checked it changes nothing.
    @ObservationIgnored private var keyChanges = 0
    /// Bumped whenever the key changes: an answer fetched with the old key is dropped rather than shown.
    @ObservationIgnored private var keyGeneration = 0
    @ObservationIgnored private var keyListTask: Task<Void, Never>?

    /// - Parameters:
    ///   - transport: How requests are sent: `HTTP.send`, unless a test stands in for OpenRouter.
    ///   - keyStore: Where the management key is kept: Sidelight's keychain item, unless a test stands in for it.
    ///   - now: The wall clock, for UTC days and ages.
    init(
        transport: @escaping Transport = { try await HTTP.send($0) }, keyStore: OpenRouterKeyStore = .keychain,
        now: @escaping () -> Date = { .now }
    ) {
        self.transport = transport
        self.keyStore = keyStore
        self.now = now
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

    /// Fetches the balance now, and the spending for `scope` if a day ended since or it failed.
    func refreshAccount(scope: OpenRouterSpendScope?) {
        balance.refreshNow()
        guard let scope, let activity = activities[scope] else { return }
        if activity.problem != nil || activity.value.map({ $0.isBehind(at: now()) }) ?? true {
            activity.refreshNow()
        }
    }

    // MARK: Demand

    private func apply() {
        guard isEnabled else {
            catalogue.policy = nil
            balance.policy = nil
            for activity in activities.values { activity.policy = nil }
            keyListTask?.cancel()
            keyListTask = nil
            keyList.isLoading = false
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

    /// The last Credits widget was removed: what the account showed is forgotten. The key stays saved.
    private func forgetAccountData() {
        guard balance.value != nil || balance.problem != nil || !activities.isEmpty || !keyList.keys.isEmpty else {
            return
        }
        balance.reset()
        for activity in activities.values { activity.policy = nil }
        activities = [:]
        keyListTask?.cancel()
        keyListTask = nil
        keyList = OpenRouterKeyList()
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
        let (result, retry) = await Self.load(request, transport: transport, at: now()) { response, date in
            OpenRouterAPI.catalogue(response, fetchedAt: date)
        }
        guard !Task.isCancelled else { return nil }
        if case .failure(let problem) = result, problem != catalogue.problem {
            Log.openRouter.notice("Can't fetch the model catalogue: \(String(describing: problem), privacy: .public)")
        }
        return FetchResult(result, retry: retry)
    }

    private func fetchBalance() async -> FetchResult<OpenRouterBalance, OpenRouterProblem>? {
        let generation = keyGeneration
        let key = await managementKey()
        guard !Task.isCancelled, generation == keyGeneration else { return nil }
        guard let key else { return .failure(.noKey, retry: .onRequest) }
        let request = OpenRouterAPI.creditsRequest(key: key, userAgent: AppInfo.userAgent)
        let (result, retry) = await Self.load(request, transport: transport, at: now()) { response, date in
            OpenRouterAPI.balance(response, fetchedAt: date)
        }
        guard !Task.isCancelled, generation == keyGeneration else { return nil }
        if case .failure(let problem) = result, problem != balance.problem {
            Log.openRouter.notice("Can't fetch the balance: \(String(describing: problem), privacy: .public)")
        }
        return FetchResult(result, retry: retry)
    }

    /// Spending for `scope`. A key's is fetched only once OpenRouter confirms the account still has the key: a key
    /// that's gone says so, rather than showing the account's spending instead.
    private func fetchActivity(
        _ scope: OpenRouterSpendScope
    ) async -> FetchResult<OpenRouterActivity, OpenRouterProblem>? {
        let generation = keyGeneration
        let key = await managementKey()
        guard !Task.isCancelled, generation == keyGeneration else { return nil }
        guard let key else { return .failure(.noKey, retry: .onRequest) }

        var scopedKey: OpenRouterKey?
        var hash: String?
        if case .key(let keyHash) = scope {
            guard let request = OpenRouterAPI.keyRequest(key: key, hash: keyHash, userAgent: AppInfo.userAgent) else {
                return .failure(.keyNotFound, retry: .onRequest)
            }
            let (found, retry) = await Self.load(request, transport: transport, at: now()) { response, _ in
                OpenRouterAPI.key(response)
            }
            guard !Task.isCancelled, generation == keyGeneration else { return nil }
            switch found {
            case .success(let found): scopedKey = found
            case .failure(let problem): return .failure(problem, retry: retry)
            }
            hash = keyHash
        }

        let request = OpenRouterAPI.activityRequest(key: key, keyHash: hash, userAgent: AppInfo.userAgent)
        let described = scopedKey
        let (result, retry) = await Self.load(request, transport: transport, at: now()) { response, date in
            OpenRouterAPI.activity(response, key: described, fetchedAt: date)
        }
        guard !Task.isCancelled, generation == keyGeneration else { return nil }
        if case .failure(let problem) = result {
            Log.openRouter.notice("Can't fetch spending: \(String(describing: problem), privacy: .public)")
        }
        return FetchResult(result, retry: retry)
    }

    /// Sends `request` and reads the answer with `read`, off the main actor: the catalogue is a megabyte of JSON.
    /// Returns when to try again if it failed.
    @concurrent
    private static func load<Value: Sendable>(
        _ request: URLRequest, transport: Transport, at date: Date,
        read: @Sendable (HTTP.Response, Date) -> Result<Value, OpenRouterProblem>
    ) async -> (Result<Value, OpenRouterProblem>, RetryAdvice) {
        let response: HTTP.Response
        do {
            response = try await transport(request)
        } catch {
            return (.failure(.unreachable), .backoff)
        }
        let result = read(response, date)
        switch result {
        case .success: return (result, .backoff)
        case .failure(let problem):
            return (result, OpenRouterAPI.retryAdvice(for: problem, headers: response.headers, now: date))
        }
    }

    // MARK: The management key

    /// Looks in the keychain for a saved key, once, so Settings can say whether there is one.
    func lookForKey() {
        guard hasKey == nil else { return }
        Task { _ = await managementKey() }
    }

    /// Checks `candidate` with OpenRouter and saves it in the keychain; returns why it wasn't saved. Only a management
    /// key can read the account's balance and spending. A key removed or saved again while it's checked is left to
    /// that newer change.
    func saveKey(_ candidate: String) async -> OpenRouterProblem? {
        let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .noKey }
        keyChanges += 1
        let change = keyChanges
        if let problem = await checkManagementKey(key) { return problem }
        guard change == keyChanges else { return nil }
        let store = keyStore
        guard await writeKey({ await store.save(key) }).value else { return .keychain }
        // A removal or save since queued its own write after this one, and already showed its result.
        guard change == keyChanges else { return nil }
        keyLoad = Task { key }
        hasKey = true
        keyChanged()
        Log.openRouter.info("Saved an OpenRouter management key")
        return nil
    }

    /// Removes the saved key, and everything it showed.
    func removeKey() {
        keyChanges += 1
        keyLoad = Task { nil }
        hasKey = false
        keyChanged()
        let store = keyStore
        writeKey { await store.delete() }
        Log.openRouter.info("Removed the OpenRouter management key")
    }

    /// Asks OpenRouter whether `key` is a management key, which can read the account.
    private func checkManagementKey(_ key: String) async -> OpenRouterProblem? {
        let request = OpenRouterAPI.currentKeyRequest(key: key, userAgent: AppInfo.userAgent)
        let (check, _) = await Self.load(request, transport: transport, at: now()) { response, _ in
            OpenRouterAPI.keyCheck(response)
        }
        switch check {
        case .failure(let problem):
            return problem
        case .success(let check) where check.isManagementKey == true:
            return nil
        case .success(let check) where check.isManagementKey == false:
            return .notManagementKey
        case .success:
            // OpenRouter didn't say: whether it may read the credits settles it.
            let request = OpenRouterAPI.creditsRequest(key: key, userAgent: AppInfo.userAgent)
            let (credits, _) = await Self.load(request, transport: transport, at: now()) { response, date in
                OpenRouterAPI.balance(response, fetchedAt: date)
            }
            switch credits {
            case .success: return nil
            case .failure(.invalidKey), .failure(.notPermitted): return .notManagementKey
            case .failure(let problem): return problem
            }
        }
    }

    /// Everything the old key showed goes, before the new one shows anything.
    private func keyChanged() {
        keyGeneration += 1
        keyListTask?.cancel()
        keyListTask = nil
        keyList = OpenRouterKeyList()
        balance.reset()
        for activity in activities.values { activity.reset() }
    }

    /// The saved key, read from the keychain the first time.
    private func managementKey() async -> String? {
        let store = keyStore
        let load = keyLoad ?? Task { await store.read() }
        keyLoad = load
        let key = await load.value
        // Saved or removed during this read: the newer answer stands.
        guard keyLoad == load else { return await managementKey() }
        if hasKey != (key != nil) { hasKey = key != nil }
        return key
    }

    /// Queues a change to the keychain item, made once the change before it is done.
    @discardableResult
    private func writeKey(_ write: @escaping @Sendable () async -> Bool) -> Task<Bool, Never> {
        let previous = keyWrite
        let task = Task {
            _ = await previous?.value
            return await write()
        }
        keyWrite = task
        return task
    }

    // MARK: Key picker

    /// Loads the first page of keys, unless it was loaded lately.
    func loadKeysIfNeeded() {
        if let fetchedAt = keyList.fetchedAt, now().timeIntervalSince(fetchedAt) < Self.keyListLifetime { return }
        guard !keyList.isLoading else { return }
        keyList = OpenRouterKeyList()
        loadMoreKeys()
    }

    /// Loads the next page of keys, up to ``maximumKeyPages`` pages.
    func loadMoreKeys() {
        guard !keyList.isLoading, let offset = keyList.nextOffset,
            offset < Self.keyPageSize * Self.maximumKeyPages
        else { return }
        keyList.isLoading = true
        let generation = keyGeneration
        keyListTask = Task { [weak self] in await self?.loadKeys(from: offset, generation: generation) }
    }

    private func loadKeys(from offset: Int, generation: Int) async {
        let key = await managementKey()
        guard !Task.isCancelled, generation == keyGeneration else { return }
        guard let key else {
            keyList.isLoading = false
            keyList.problem = .noKey
            return
        }
        let request = OpenRouterAPI.keysRequest(key: key, offset: offset, userAgent: AppInfo.userAgent)
        let (result, _) = await Self.load(request, transport: transport, at: now()) { response, _ in
            OpenRouterAPI.keys(response)
        }
        guard !Task.isCancelled, generation == keyGeneration else { return }
        keyList.isLoading = false
        switch result {
        case .success(let page):
            // Keys created or deleted between pages can shift them: keep the first of any repeat.
            let known = Set(keyList.keys.map(\.hash))
            keyList.keys += page.filter { !known.contains($0.hash) }
            keyList.nextOffset = page.count >= Self.keyPageSize ? offset + page.count : nil
            keyList.problem = nil
            if offset == 0 { keyList.fetchedAt = now() }
        case .failure(let problem):
            keyList.problem = problem
        }
    }
}
