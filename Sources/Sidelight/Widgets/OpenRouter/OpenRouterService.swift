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
/// OpenRouter account a Balance block uses, that account's balance and spending.
///
/// Each kind of data is a ``RemoteResource`` of its own, fetched once for every widget showing it, as often as the
/// most frequent of them asks and only while one is on screen. Showing models never reads a key; showing a balance
/// never downloads the catalogue. Each account is an ``OpenRouterAccount`` of its own, paced on its own, and shared by
/// every block that uses it: two blocks on the same account make one set of requests.
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
    /// The accounts Balance blocks in the configuration use, while they do.
    private(set) var accounts: [AccountID: OpenRouterAccount] = [:]

    /// What the widgets on screen need. Set from the configuration.
    var demand = OpenRouterDemand() {
        didSet {
            guard demand != oldValue else { return }
            apply()
        }
    }

    @ObservationIgnored private let client: OpenRouterClient
    @ObservationIgnored private let access: AccountAccess
    @ObservationIgnored private let manualActionGap: Duration
    @ObservationIgnored private var isEnabled = false

    /// - Parameters:
    ///   - transport: How requests are sent: `HTTP.send`, unless a test stands in for OpenRouter.
    ///   - accounts: Reads each account's key, and hears how each is doing.
    ///   - manualActionGap: How far apart someone's clicks that ask with a key are sent, at least.
    ///   - now: The wall clock, for UTC days and ages.
    init(
        transport: @escaping Transport = { try await HTTP.send($0) }, accounts: AccountAccess,
        manualActionGap: Duration = OpenRouterService.manualActionGap, now: @escaping @Sendable () -> Date = { .now }
    ) {
        let client = OpenRouterClient(transport: transport, now: now)
        self.client = client
        access = accounts
        self.manualActionGap = manualActionGap
        catalogue = RemoteResource(now: now)
        catalogue.fetch = { [weak self] in await self?.fetchCatalogue() }
        accounts.observeChanges { [weak self] id in self?.accounts[id]?.keyChanged() }
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

    /// The account `id`, while a Balance block in the configuration uses it.
    func account(_ id: AccountID) -> OpenRouterAccount? {
        accounts[id]
    }

    /// Fetches the catalogue now, or as soon as allowed.
    func refreshCatalogue() {
        catalogue.refreshNow()
    }

    // MARK: Demand

    private func apply() {
        catalogue.policy = isEnabled ? demand.catalogue.map { RefreshPolicy($0) } : nil
        for id in demand.keptAccounts where accounts[id] == nil {
            let access = access
            accounts[id] = OpenRouterAccount(
                id: id, client: client, secret: { () throws(KeychainUnavailable) in try await access.secret(id) },
                report: { access.report($0, id) },
                manualActionGap: manualActionGap)
        }
        for (id, account) in accounts where !demand.keptAccounts.contains(id) {
            // No block uses it any more: what it showed goes. Its key stays the account's.
            account.update(demand: OpenRouterAccountDemand(), isKept: false, isEnabled: false)
            accounts[id] = nil
        }
        for account in accounts.values {
            account.update(demand: demand.account(account.id), isKept: true, isEnabled: isEnabled)
        }
    }

    // MARK: Keys

    /// Asks OpenRouter whether `candidate` is a management key, which can read an account's balance and spending;
    /// returns why it can't be used. Asks once with the candidate itself, whatever any account's pace: it's a
    /// different key, and someone just asked.
    func checkKey(_ candidate: String) async -> OpenRouterProblem? {
        let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .noKey }
        let check = await client.send(OpenRouterAPI.currentKeyRequest(key: key, userAgent: AppInfo.userAgent)) {
            response, _ in OpenRouterAPI.keyCheck(response)
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
            let credits = await client.send(OpenRouterAPI.creditsRequest(key: key, userAgent: AppInfo.userAgent)) {
                OpenRouterAPI.balance($0, fetchedAt: $1)
            }
            switch credits.result {
            case .success: return nil
            case .failure(.invalidKey), .failure(.notPermitted): return .notManagementKey
            case .failure(let problem): return problem
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
