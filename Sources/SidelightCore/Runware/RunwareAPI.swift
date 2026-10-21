import Foundation

/// Why something couldn't be fetched from Runware.
public enum RunwareProblem: Error, Equatable, Sendable {
    /// No API key is saved in Sidelight for the account.
    case noKey
    /// The Runware CLI has no saved key: no `~/.runware/config.yaml`, or no `api_key` in it.
    case cliNotSignedIn
    /// The CLI's `config.yaml` is there, but not in a shape Sidelight reads safely.
    case cliConfigUnreadable
    /// Runware doesn't accept the key (401, or `invalidApiKey`).
    case invalidKey
    /// The key may not read this (403).
    case notPermitted
    /// Asked too often (429).
    case rateLimited
    /// Runware had a problem (5xx).
    case unavailable(status: Int)
    /// Runware turned the request down, with its code and explanation when it gave them. Asking again won't help.
    case badRequest(code: String?, message: String?)
    /// An answer that isn't what Runware documents, or is missing the part asked for.
    case unreadable
    /// An answer far larger than these ever are.
    case tooLarge
    /// No answer at all: offline, or Runware can't be reached.
    case unreachable
    /// The account's key couldn't be read from the keychain just now.
    case keychain

    /// The problem without Runware's own message, which may echo what was sent: safe for a public log.
    public var logDescription: String {
        if case .badRequest(let code, _) = self { return "badRequest(code: \(code ?? "nil"))" }
        return String(describing: self)
    }
}

/// What one day's usage is broken down by, in a usage activity request.
public enum RunwareActivityGrouping: String, Sendable {
    case date
    case model
}

/// Runware's HTTP API, as far as Sidelight reads it: building requests and reading answers into Sidelight's types.
/// Network calls happen elsewhere, through `HTTP.send`.
///
/// Every request is a POST of an array of tasks, each with a fresh `taskUUID`; answers are matched to tasks by it.
/// Sidelight only ever sends the read-only tasks in ``readOnlyTaskTypes``: it never runs a generation.
///
/// Documented at `https://runware.ai/docs/platform/account-management` and `…/platform/model-search`.
public enum RunwareAPI {
    public static let endpoint = URL(string: "https://api.runware.ai/v1")!
    static let timeout: TimeInterval = 30
    /// Account and search answers are a few kilobytes; anything past this isn't read.
    public static let sizeLimit = 2 * 1024 * 1024
    /// The only task types Sidelight ever sends. A test asserts every request uses one of them.
    public static let readOnlyTaskTypes: Set<String> = ["accountManagement", "modelSearch"]
    /// Runware's error messages are cut to this many characters before they're shown.
    static let messageLimit = 200

    // MARK: Requests

    /// The organization's name, balance, rolling usage and API keys.
    public static func detailsRequest(key: String, taskUUID: UUID, userAgent: String) -> URLRequest {
        request(
            [["taskType": "accountManagement", "taskUUID": taskUUID.uuidString, "operation": "getDetails"]],
            key: key, userAgent: userAgent)
    }

    /// Requests and spend over the UTC days of `window`, broken down by `groupBy`.
    public static func activityRequest(
        key: String, window: ClosedRange<UTCDay>, groupBy: [RunwareActivityGrouping], taskUUID: UUID,
        userAgent: String
    ) -> URLRequest {
        request(
            [
                [
                    "taskType": "accountManagement", "taskUUID": taskUUID.uuidString, "operation": "getUsageActivity",
                    "startDate": window.lowerBound.description, "endDate": window.upperBound.description,
                    "groupBy": groupBy.map(\.rawValue), "timezone": "UTC",
                ]
            ], key: key, userAgent: userAgent)
    }

    /// One page of Runware's model catalogue matching `query`.
    public static func modelSearchRequest(
        key: String, query: RunwareModelQuery, taskUUID: UUID, userAgent: String
    ) -> URLRequest {
        var task: [String: Any] = [
            "taskType": "modelSearch", "taskUUID": taskUUID.uuidString, "limit": RunwareModelQuery.pageSize,
        ]
        let search = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty { task["search"] = search }
        if let category = query.category { task["category"] = category }
        if let source = query.source { task["source"] = source }
        if let visibility = query.visibility { task["visibility"] = visibility }
        if query.offset > 0 { task["offset"] = query.offset }
        return request([task], key: key, userAgent: userAgent)
    }

    private static func request(_ tasks: [[String: Any]], key: String, userAgent: String) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: tasks, options: [.sortedKeys])
        return request
    }

    // MARK: Answers

    /// The account details in `response`. A balance that can't be read makes the whole answer unreadable: a balance
    /// widget without a balance is a failure, never a zero. Anything else odd leaves just that value unknown.
    public static func details(
        _ response: HTTP.Response, taskUUID: UUID, fetchedAt: Date
    ) -> Result<RunwareAccountDetails, RunwareProblem> {
        task(DetailsPayload.self, in: response, taskUUID: taskUUID).flatMap { payload in
            guard let balance = payload.balance else { return .failure(.unreadable) }
            return .success(
                RunwareAccountDetails(
                    organizationName: payload.organizationName, organizationID: payload.organizationID,
                    balance: balance, usage: payload.usage, apiKeys: payload.apiKeys, fetchedAt: fetchedAt))
        }
    }

    /// Usage over `window` in `response`. A row that can't be read is left out rather than failing the answer: usage
    /// isn't money owed, and losing one day is better than losing the chart.
    public static func activity(
        _ response: HTTP.Response, taskUUID: UUID, window: ClosedRange<UTCDay>, fetchedAt: Date
    ) -> Result<RunwareActivity, RunwareProblem> {
        task(ActivityPayload.self, in: response, taskUUID: taskUUID).map { payload in
            RunwareActivity(
                window: window, days: payload.days, models: payload.models, totalRequests: payload.totalRequests,
                totalSpend: payload.totalSpend, fetchedAt: fetchedAt)
        }
    }

    /// One page of models in `response`. Models without an AIR are skipped, and one listed twice is kept once.
    public static func modelPage(
        _ response: HTTP.Response, taskUUID: UUID, query: RunwareModelQuery
    ) -> Result<RunwareModelPage, RunwareProblem> {
        task(ModelSearchPayload.self, in: response, taskUUID: taskUUID).map { payload in
            var seen = Set<String>()
            let models = payload.models.filter { seen.insert($0.air).inserted }
            return RunwareModelPage(
                models: models, entryCount: payload.entryCount, total: payload.total, query: query)
        }
    }

    /// When to try again after `problem`: when Runware said (`retryAfter` in the answer, or `Retry-After`), backing
    /// off from passing trouble, and not on its own at all when only a change can help.
    public static func retryAdvice(
        for problem: RunwareProblem, response: HTTP.Response? = nil, now: Date
    ) -> RetryAdvice {
        switch problem {
        case .rateLimited, .unavailable:
            let said = response.flatMap {
                retryAfter(in: $0.body, now: now) ?? RetryAfter.date(in: $0.headers, now: now)
            }
            return said.map(RetryAdvice.notBefore) ?? .backoff
        case .unreachable, .unreadable, .tooLarge, .keychain:
            return .backoff
        case .noKey, .cliNotSignedIn, .cliConfigUnreadable, .invalidKey, .notPermitted, .badRequest:
            return .onRequest
        }
    }

    /// Our task's answer in `response`: first what the status says, then an error Runware listed for the task, then
    /// its data. An answer can carry another task's error and our data at once, so errors go by `taskUUID`.
    static func task<Payload: RunwareTaskPayload>(
        _ type: Payload.Type, in response: HTTP.Response, taskUUID: UUID
    ) -> Result<Payload, RunwareProblem> {
        if response.body.count > sizeLimit { return .failure(.tooLarge) }
        let envelope = try? JSONDecoder().decode(Envelope<Payload>.self, from: response.body)
        let ours = taskUUID.uuidString.lowercased()
        let errors = (envelope?.errors ?? []).compactMap(\.value)
        // An error naming no task is about the whole request, so ours too.
        let error = errors.first { $0.taskUUID?.lowercased() == ours } ?? errors.first { $0.taskUUID == nil }
        switch response.status {
        case 200..<300: break
        case 401: return .failure(.invalidKey)
        case 403: return .failure(.notPermitted)
        case 429: return .failure(.rateLimited)
        case 500..<600: return .failure(.unavailable(status: response.status))
        case 400..<500: return .failure(error.map { problem(for: $0) } ?? .badRequest(code: nil, message: nil))
        default: return .failure(.unreadable)
        }
        if let error { return .failure(problem(for: error)) }
        guard
            let payload = (envelope?.data ?? []).compactMap(\.value).first(where: { $0.taskUUID?.lowercased() == ours })
        else { return .failure(.unreadable) }
        return .success(payload)
    }

    /// What an error Runware listed means.
    private static func problem(for error: ErrorPayload) -> RunwareProblem {
        let code = error.code ?? ""
        let lowercased = code.lowercased()
        if lowercased == "invalidapikey" || lowercased.contains("unauthori") { return .invalidKey }
        if lowercased.contains("ratelimit") || lowercased.contains("toomanyrequests") { return .rateLimited }
        if lowercased.contains("forbidden") || lowercased.contains("permission") { return .notPermitted }
        return .badRequest(
            code: code.isEmpty ? nil : code, message: error.message.map { String($0.prefix(messageLimit)) })
    }

    /// `retryAfter` in an error of the answer: seconds, or an ISO 8601 date. Capped like `Retry-After`.
    static func retryAfter(in body: Data, now: Date) -> Date? {
        guard let envelope = try? JSONDecoder().decode(Envelope<NoPayload>.self, from: body) else { return nil }
        for error in (envelope.errors ?? []).compactMap(\.value) {
            if let seconds = error.retryAfterSeconds, seconds >= 0 {
                return now.addingTimeInterval(min(seconds, RetryAfter.maximumWait))
            }
            if let date = error.retryAfterDate {
                return min(max(date, now), now.addingTimeInterval(RetryAfter.maximumWait))
            }
        }
        return nil
    }
}

// MARK: - Payloads

/// One task's part of an answer, matched to its task by `taskUUID`.
protocol RunwareTaskPayload: Decodable {
    var taskUUID: String? { get }
}

/// `{"data": [ … ], "errors": [ … ]}`, either part possibly missing.
private struct Envelope<Payload: Decodable>: Decodable {
    let data: [LenientElement<Payload>]?
    let errors: [LenientElement<ErrorPayload>]?
}

private struct NoPayload: Decodable {}

private struct ErrorPayload: Decodable {
    let code: String?
    let message: String?
    let taskUUID: String?
    let retryAfterSeconds: TimeInterval?
    let retryAfterDate: Date?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        code = container.lenient(String.self, "code")
        message = container.lenient(String.self, "message")
        taskUUID = container.lenient(String.self, "taskUUID")
        retryAfterSeconds = container.lenientDouble("retryAfter").flatMap { $0.isFinite ? $0 : nil }
        retryAfterDate = container.lenient(String.self, "retryAfter").flatMap(Date.init(iso8601:))
    }
}

/// Reads the nested object under `key`, if there is one.
private func object(
    _ container: KeyedDecodingContainer<AnyCodingKey>?, _ key: String
) -> KeyedDecodingContainer<AnyCodingKey>? {
    try? container?.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey(key))
}

/// The readable elements of the array under `key`; unreadable ones are left out.
private func elements<Element: Decodable>(
    _ type: Element.Type, _ container: KeyedDecodingContainer<AnyCodingKey>?, _ key: String
) -> [Element] {
    (container?.lenient([LenientElement<Element>].self, key) ?? []).compactMap(\.value)
}

/// A count, which must be a whole number of zero or more.
private func count(_ container: KeyedDecodingContainer<AnyCodingKey>?, _ key: String) -> Int? {
    container?.lenientInt64(key).flatMap { $0 >= 0 ? Int(exactly: $0) : nil }
}

private struct DetailsPayload: RunwareTaskPayload {
    let taskUUID: String?
    let organizationName: String?
    let organizationID: String?
    /// `nil` when it can't be read.
    let balance: RunwareBalance?
    let usage: RunwareRollingUsage
    let apiKeys: [RunwareAPIKeySummary]

    // `team` (people's names and emails) and the masked key strings are never read.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        taskUUID = container.lenient(String.self, "taskUUID")
        organizationName = container.lenient(String.self, "organizationName").flatMap { $0.isEmpty ? nil : $0 }
        organizationID = container.lenient(String.self, "organizationUUID")
        if let balance = object(container, "balance") {
            if case .amount(let amount) = ReportedAmount(balance, "amount") {
                let currency = balance.lenient(String.self, "currency").flatMap { $0.isEmpty ? nil : $0.uppercased() }
                self.balance = RunwareBalance(
                    amount: amount, freeBalance: ReportedAmount(balance, "freeBalance").value,
                    currency: currency ?? "USD")
            } else {
                self.balance = nil
            }
        } else if case .amount(let amount) = ReportedAmount(container, "balance") {
            // The CLI reads the balance as a bare number.
            balance = RunwareBalance(amount: amount, freeBalance: nil, currency: "USD")
        } else {
            balance = nil
        }
        let usage = object(container, "usage")
        func total(_ key: String) -> RunwareUsageTotal? {
            guard let period = object(usage, key) else { return nil }
            return RunwareUsageTotal(
                spend: ReportedAmount(period, "credits").value, requests: count(period, "requests"))
        }
        self.usage = RunwareRollingUsage(
            today: total("today"), last7Days: total("last7Days"), last30Days: total("last30Days"),
            total: total("total"))
        apiKeys = elements(KeyPayload.self, container, "apiKeys").map(\.key)
    }
}

private struct KeyPayload: Decodable {
    let key: RunwareAPIKeySummary

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let name = container.lenient(String.self, "name").flatMap { $0.isEmpty ? nil : $0 }
        key = RunwareAPIKeySummary(
            name: name ?? "Unnamed key", isEnabled: container.lenient(Bool.self, "enabled") ?? true,
            requests: count(container, "requests"),
            createdAt: container.lenient(String.self, "createdAt").flatMap(Date.init(iso8601:)),
            lastUsedAt: container.lenient(String.self, "lastUsedAt").flatMap(Date.init(iso8601:)))
    }
}

private struct ActivityPayload: RunwareTaskPayload {
    let taskUUID: String?
    let days: [RunwareActivity.Row]
    let models: [RunwareActivity.ModelRow]
    let totalRequests: Int?
    let totalSpend: Decimal?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        taskUUID = container.lenient(String.self, "taskUUID")
        // Without `usage` the answer says nothing: unreadable, so what was shown stays rather than reading as no use.
        let usage = try container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("usage"))
        let timeseries = object(usage, "timeseries")
        days = elements(RowPayload.self, timeseries, "data").compactMap(\.row)
        models = elements(ModelRowPayload.self, object(usage, "model"), "data").compactMap(\.row)
        let meta = object(timeseries, "meta")
        totalRequests = count(meta, "totalRequests")
        totalSpend = meta.flatMap { ReportedAmount($0, "totalSpend").value }
    }
}

private struct RowPayload: Decodable {
    let row: RunwareActivity.Row?

    init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: AnyCodingKey.self),
            let day = container.lenient(String.self, "date").flatMap(UTCDay.init(iso:))
        else {
            row = nil
            return
        }
        row = RunwareActivity.Row(
            day: day, requests: count(container, "count"), spend: ReportedAmount(container, "spend").value)
    }
}

private struct ModelRowPayload: Decodable {
    let row: RunwareActivity.ModelRow?

    init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: AnyCodingKey.self),
            let air = container.lenient(String.self, "model"), !air.isEmpty
        else {
            row = nil
            return
        }
        row = RunwareActivity.ModelRow(
            day: container.lenient(String.self, "date").flatMap(UTCDay.init(iso:)), air: air,
            name: container.lenient(String.self, "modelName").flatMap { $0.isEmpty ? nil : $0 },
            requests: count(container, "count"), spend: ReportedAmount(container, "spend").value)
    }
}

private struct ModelSearchPayload: RunwareTaskPayload {
    let taskUUID: String?
    let models: [RunwareModel]
    /// How many results Runware listed, readable or not: whether another page follows.
    let entryCount: Int
    let total: Int?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        taskUUID = container.lenient(String.self, "taskUUID")
        let results = container.lenient([LenientElement<ModelPayload>].self, "results") ?? []
        models = results.compactMap { $0.value?.model }
        entryCount = results.count
        total = count(container, "totalResults")
    }
}

private struct ModelPayload: Decodable {
    let model: RunwareModel?

    init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: AnyCodingKey.self),
            let air = container.lenient(String.self, "air"), !air.isEmpty
        else {
            model = nil
            return
        }
        func text(_ key: String) -> String? { container.lenient(String.self, key).flatMap { $0.isEmpty ? nil : $0 } }
        func size(_ key: String) -> Int? { count(container, key).flatMap { $0 > 0 ? $0 : nil } }
        model = RunwareModel(
            air: air, name: text("name") ?? air, version: text("version"), category: text("category"),
            architecture: text("architecture"), type: text("type"),
            tags: container.lenient([String].self, "tags") ?? [],
            isPrivate: container.lenient(Bool.self, "private") ?? false,
            heroImage: text("heroImage").flatMap(URL.init(string:)),
            defaultWidth: size("defaultWidth"), defaultHeight: size("defaultHeight"),
            defaultSteps: size("defaultSteps"),
            defaultCFG: container.lenientDouble("defaultCFG").flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
    }
}
