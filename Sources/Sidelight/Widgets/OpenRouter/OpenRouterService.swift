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

/// OpenRouter for every OpenRouter widget and the model catalogue's details panel: the public catalogue, and for each
/// key saved in Sidelight, that account's balance and spending.
///
/// Each kind of data is a ``RemoteResource`` of its own, fetched once for every widget showing it, as often as the
/// most frequent of them asks and only while one is on screen. Showing models never reads a key; showing a balance
/// never downloads the catalogue. Each key's account is an ``OpenRouterAccount`` of its own, paced on its own: the
/// shared key's, and one for each Balance block with its own key. Once no block in the configuration uses its own
/// key any more (the block or its widget was removed, or it went back to the shared key), that key is removed from
/// the keychain.
@Observable
final class OpenRouterService: DataService {
    typealias Transport = OpenRouterClient.Transport

    /// The key picker loads at most this many pages of keys.
    static let maximumKeyPages = 20
    /// OpenRouter lists keys this many to a page; a shorter page is the last.
    static let keyPageSize = 100
    /// The key picker loads the list again after this long.
    static let keyListLifetime: TimeInterval = 30 * 60
    /// Someone's requests with a key (a refresh, another page of keys) are this far apart at least. The requests of
    /// one click go together.
    static let manualActionGap: Duration = .seconds(15)
    /// Spending is fetched this long after midnight UTC, once the day just ended has been counted.
    static let activityDelay: Duration = .seconds(10 * 60)

    let catalogue: RemoteResource<OpenRouterCatalogue, OpenRouterProblem>
    /// The shared key's account, which every Balance block without its own key reads.
    let shared: OpenRouterAccount
    /// The accounts of Balance blocks with their own key, while the configuration has them.
    private(set) var ownAccounts: [OpenRouterAccountID: OpenRouterAccount] = [:]

    /// What the widgets on screen need. Set from the configuration.
    var demand = OpenRouterDemand() {
        didSet {
            guard demand != oldValue else { return }
            apply()
        }
    }

    @ObservationIgnored private let client: OpenRouterClient
    @ObservationIgnored private let keys: OpenRouterKeyring
    @ObservationIgnored private let manualActionGap: Duration
    @ObservationIgnored private var isEnabled = false
    /// Own keys added for a block that doesn't use its own key yet: it switches to it once the key is saved, and the
    /// configuration says so soon after. Kept until then, rather than removed as unused.
    @ObservationIgnored private var addedOwnKeys: Set<OpenRouterAccountID> = []
    /// Removals of own keys still under way: a key added for the same block again waits for its removal.
    @ObservationIgnored private var ownKeyRemovals: [OpenRouterAccountID: Task<OpenRouterProblem?, Never>] = [:]

    /// - Parameters:
    ///   - transport: How requests are sent: `HTTP.send`, unless a test stands in for OpenRouter.
    ///   - keys: Where each account's management key and its removal are kept: Sidelight's keychain items, unless a
    ///     test stands in for them.
    ///   - manualActionGap: How far apart someone's clicks that ask with a key are sent, at least.
    ///   - now: The wall clock, for UTC days and ages.
    init(
        transport: @escaping Transport = { try await HTTP.send($0) }, keys: OpenRouterKeyring = .keychain,
        manualActionGap: Duration = OpenRouterService.manualActionGap, now: @escaping @Sendable () -> Date = { .now }
    ) {
        let client = OpenRouterClient(transport: transport, now: now)
        self.client = client
        self.keys = keys
        self.manualActionGap = manualActionGap
        catalogue = RemoteResource(now: now)
        shared = OpenRouterAccount(
            id: .shared, client: client, keyStore: keys.store(.shared), manualActionGap: manualActionGap)
        catalogue.fetch = { [weak self] in await self?.fetchCatalogue() }
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

    /// The account `id` reads: the shared one, or a Balance block's own while the configuration has that block.
    func account(_ id: OpenRouterAccountID) -> OpenRouterAccount? {
        id == .shared ? shared : ownAccounts[id]
    }

    /// Fetches the catalogue now, or as soon as allowed.
    func refreshCatalogue() {
        catalogue.refreshNow()
    }

    // MARK: Demand

    private func apply() {
        catalogue.policy = isEnabled ? demand.catalogue.map { RefreshPolicy($0) } : nil
        // Blocks that use their own key now have an account; those that no longer do lose it, and their key.
        addedOwnKeys.subtract(demand.keptAccounts)
        let kept = demand.keptAccounts.union(addedOwnKeys)
        for id in kept where id != .shared && ownAccounts[id] == nil {
            ownAccounts[id] = makeAccount(id)
        }
        for (id, account) in ownAccounts where !kept.contains(id) {
            account.update(demand: OpenRouterAccountDemand(), isKept: false, isEnabled: false)
            let removal = account.removeKey()
            ownKeyRemovals[id] = removal
            Task { [weak self] in
                _ = await removal.value
                if self?.ownKeyRemovals[id] == removal { self?.ownKeyRemovals[id] = nil }
            }
            ownAccounts[id] = nil
            Log.openRouter.info("Removed a Balance block's own OpenRouter key, as no block uses it any more")
        }
        for account in [shared] + Array(ownAccounts.values) {
            account.update(
                demand: demand.account(account.id), isKept: demand.keptAccounts.contains(account.id),
                isEnabled: isEnabled)
        }
    }

    private func makeAccount(_ id: OpenRouterAccountID) -> OpenRouterAccount {
        OpenRouterAccount(id: id, client: client, keyStore: keys.store(id), manualActionGap: manualActionGap)
    }

    /// Checks `candidate` with OpenRouter and saves it as the own key of the Balance block `id` reads, before the
    /// block switches to it; returns why it wasn't saved. A removal of that block's earlier own key still under way
    /// finishes first, so it can't delete this one. Once saved, the key stays until the configuration has had time
    /// to say the block uses it.
    func addOwnKey(_ candidate: String, for id: OpenRouterAccountID) async -> OpenRouterProblem? {
        guard id != .shared else { return await shared.saveKey(candidate) }
        _ = await ownKeyRemovals[id]?.value
        let account = ownAccounts[id] ?? makeAccount(id)
        if let problem = await account.saveKey(candidate) { return problem }
        // Given up on, or overtaken, before it was written.
        guard account.canUseKey else { return nil }
        ownAccounts[id] = account
        if !demand.keptAccounts.contains(id) { addedOwnKeys.insert(id) }
        return nil
    }

    /// Saves the keys of `widget`'s Balance blocks that use their own for the same blocks of `copy`, a duplicate not
    /// added yet, so it reads the same accounts. Done before it's added, so its accounts never find no key.
    func copyOwnKeys(of widget: WidgetInstance, to copy: WidgetInstance.ID) async {
        guard case .openRouter(let settings) = widget.settings else { return }
        for (id, options) in settings.allBalances where options.account(widget: widget.id, block: id) != .shared {
            guard let key = await ownAccounts[.own(widget: widget.id, block: id)]?.key() else { continue }
            if await !keys.store(.own(widget: copy, block: id)).save(key) {
                Log.openRouter.error("Couldn't copy a Balance block's own OpenRouter key to a duplicated widget")
            }
        }
    }

    // MARK: Fetching

    private func fetchCatalogue() async -> FetchResult<OpenRouterCatalogue, OpenRouterProblem>? {
        let answer = await client.send(OpenRouterAPI.modelsRequest(userAgent: AppInfo.userAgent)) { response, date in
            OpenRouterAPI.catalogue(response, fetchedAt: date)
        }
        guard !Task.isCancelled else { return nil }
        if case .failure(let problem) = answer.result, problem != catalogue.problem {
            Log.openRouter.notice("Can't fetch the model catalogue: \(String(describing: problem), privacy: .public)")
        }
        return answer.fetchResult
    }
}

/// How Sidelight asks OpenRouter: sends a request through the transport and reads the answer, off the main actor,
/// with the time it came for what it covers.
nonisolated struct OpenRouterClient: Sendable {
    /// Sends a request and returns OpenRouter's answer; throws when no answer came back at all.
    typealias Transport = @Sendable (URLRequest) async throws -> HTTP.Response

    let transport: Transport
    /// The wall clock, for UTC days and ages.
    let now: @Sendable () -> Date

    /// What one request came back with, and when.
    struct Answer<Value: Sendable>: Sendable {
        let result: Result<Value, OpenRouterProblem>
        /// When to try again, if it failed.
        let retry: RetryAdvice
        /// When the answer came: what it covers, like the last completed UTC day, is counted from then.
        let date: Date
    }

    /// Sends `request` and reads the answer with `read`, off the main actor: the catalogue is a megabyte of JSON.
    @concurrent
    func send<Value: Sendable>(
        _ request: URLRequest, read: @Sendable (HTTP.Response, Date) -> Result<Value, OpenRouterProblem>
    ) async -> Answer<Value> {
        let response: HTTP.Response
        do {
            response = try await transport(request)
        } catch {
            return Answer(result: .failure(.unreachable), retry: .backoff, date: now())
        }
        let date = now()
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
}

extension OpenRouterClient.Answer {
    /// The answer, for a ``RemoteResource``.
    var fetchResult: FetchResult<Value, OpenRouterProblem> {
        FetchResult(result, retry: retry, at: date)
    }
}
