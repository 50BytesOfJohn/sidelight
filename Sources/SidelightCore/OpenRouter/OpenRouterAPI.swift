import Foundation

/// Why something couldn't be fetched from OpenRouter.
public enum OpenRouterProblem: Error, Equatable, Sendable {
    /// No management key is saved in Sidelight.
    case noKey
    /// OpenRouter doesn't accept the key (401).
    case invalidKey
    /// The key may not read this (403).
    case notPermitted
    /// An inference key: it can't read the account's credits or activity.
    case notManagementKey
    /// The chart's key isn't in the account any more.
    case keyNotFound
    /// Asked too often (429).
    case rateLimited
    /// OpenRouter had a problem (5xx, including 503).
    case unavailable(status: Int)
    /// OpenRouter rejected the request (400), with its explanation when it gave one. Asking again won't help.
    case badRequest(message: String?)
    /// An answer that isn't what OpenRouter documents, or is missing part of it.
    case unreadable
    /// An answer far larger than the catalogue ever is.
    case tooLarge
    /// No answer at all: offline, or OpenRouter can't be reached.
    case unreachable
    /// The account's key couldn't be read from the keychain just now.
    case keychain
}

/// OpenRouter's HTTP API: building requests, and reading answers into Sidelight's types. Network calls happen
/// elsewhere, through `HTTP.send`.
public enum OpenRouterAPI {
    public static let baseURL = URL(string: "https://openrouter.ai/api/v1/")!
    /// The whole catalogue was about 1 MB in October 2026. Anything past this isn't parsed.
    public static let catalogueSizeLimit = 5 * 1024 * 1024
    /// Account answers are small; the key list is the largest.
    public static let accountSizeLimit = 2 * 1024 * 1024
    static let timeout: TimeInterval = 30

    // MARK: Requests

    /// Every model, of every kind: without `output_modalities=all`, OpenRouter lists only those producing text. No
    /// credential: the catalogue is public.
    public static func modelsRequest(userAgent: String) -> URLRequest {
        request(
            path: "models", query: [URLQueryItem(name: "output_modalities", value: "all")], key: nil,
            userAgent: userAgent)
    }

    /// The account's credits bought and used. Needs a management key.
    public static func creditsRequest(key: String, userAgent: String) -> URLRequest {
        request(path: "credits", key: key, userAgent: userAgent)
    }

    /// Spending over the last 30 completed UTC days, by day, model and provider, for the account or one key.
    /// Needs a management key.
    public static func activityRequest(key: String, keyHash: String?, userAgent: String) -> URLRequest {
        request(
            path: "activity", query: keyHash.map { [URLQueryItem(name: "api_key_hash", value: $0)] } ?? [], key: key,
            userAgent: userAgent)
    }

    /// One page of the account's keys in its default workspace, disabled and expired ones included so a chosen key
    /// that was disabled or expired can still be named. Needs a management key.
    public static func keysRequest(key: String, offset: Int, userAgent: String) -> URLRequest {
        var query = [
            URLQueryItem(name: "include_disabled", value: "true"),
            URLQueryItem(name: "include_expired", value: "true"),
        ]
        if offset > 0 { query.append(URLQueryItem(name: "offset", value: String(offset))) }
        return request(path: "keys", query: query, key: key, userAgent: userAgent)
    }

    /// One key, by hash; `nil` for a hash that can't be one. Needs a management key.
    public static func keyRequest(key: String, hash: String, userAgent: String) -> URLRequest? {
        guard isPlausibleHash(hash) else { return nil }
        return request(path: "keys/\(hash)", key: key, userAgent: userAgent)
    }

    /// The key making the request, to check what it may do before it's saved.
    public static func currentKeyRequest(key: String, userAgent: String) -> URLRequest {
        request(path: "key", key: key, userAgent: userAgent)
    }

    /// Key hashes are 64 hexadecimal digits (a SHA-256); anything else never goes into a URL.
    public static func isPlausibleHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    private static func request(
        path: String, query: [URLQueryItem] = [], key: String?, userAgent: String
    ) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        var request = URLRequest(url: components?.url ?? baseURL.appending(path: path), timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }

    // MARK: Answers

    /// The catalogue in `response`. Models missing an ID are skipped; any other odd field leaves just that value
    /// unknown.
    public static func catalogue(
        _ response: HTTP.Response, fetchedAt: Date
    ) -> Result<OpenRouterCatalogue, OpenRouterProblem> {
        if let problem = problem(in: response, sizeLimit: catalogueSizeLimit) { return .failure(problem) }
        guard let payload = try? JSONDecoder().decode(ListPayload<ModelPayload>.self, from: response.body) else {
            return .failure(.unreadable)
        }
        let models = payload.data.compactMap(\.model)
        // Ids are unique in the catalogue; a repeat would make rows ambiguous.
        var seen = Set<String>()
        let unique = models.filter { seen.insert($0.id).inserted }
        return .success(OpenRouterCatalogue(models: unique, fetchedAt: fetchedAt))
    }

    /// The account's balance in `response`. Both totals must be there: one alone can't give a balance.
    public static func balance(
        _ response: HTTP.Response, fetchedAt: Date
    ) -> Result<OpenRouterBalance, OpenRouterProblem> {
        if let problem = problem(in: response, sizeLimit: accountSizeLimit) { return .failure(problem) }
        guard let payload = try? JSONDecoder().decode(ObjectPayload<CreditsPayload>.self, from: response.body),
            case .amount(let credits) = payload.data.totalCredits, case .amount(let usage) = payload.data.totalUsage
        else { return .failure(.unreadable) }
        return .success(OpenRouterBalance(totalCredits: credits, totalUsage: usage, fetchedAt: fetchedAt))
    }

    /// Spending by day in `response`. Money is never guessed: a row whose day or amount can't be read makes the
    /// whole answer unreadable, rather than a total that looks complete but isn't. A row without BYOK usage has
    /// none; one whose BYOK usage is there but unreadable is unreadable too.
    public static func activity(
        _ response: HTTP.Response, key: OpenRouterKey?, fetchedAt: Date
    ) -> Result<OpenRouterActivity, OpenRouterProblem> {
        if let problem = problem(in: response, sizeLimit: accountSizeLimit) { return .failure(problem) }
        guard let payload = try? JSONDecoder().decode(ListPayload<ActivityRowPayload>.self, from: response.body)
        else { return .failure(.unreadable) }
        var rows: [(day: UTCDay, usage: Decimal, byok: Decimal?)] = []
        for row in payload.data {
            guard let day = row.day, case .amount(let usage) = row.usage else { return .failure(.unreadable) }
            switch row.byokUsage {
            case .absent: rows.append((day, usage, nil))
            case .amount(let byok): rows.append((day, usage, byok))
            case .unreadable: return .failure(.unreadable)
            }
        }
        return .success(OpenRouterActivity(rows: rows, fetchedAt: fetchedAt, key: key))
    }

    /// One page of keys in `response`. Entries without a readable hash are skipped, but still count towards the
    /// page's length, which says whether more pages follow; a key listed twice is kept once.
    public static func keyPage(_ response: HTTP.Response) -> Result<OpenRouterKeyPage, OpenRouterProblem> {
        if let problem = problem(in: response, sizeLimit: accountSizeLimit) { return .failure(problem) }
        guard let payload = try? JSONDecoder().decode(ListPayload<KeyPayload>.self, from: response.body) else {
            return .failure(.unreadable)
        }
        var seen = Set<String>()
        let keys = payload.data.compactMap(\.key).filter { seen.insert($0.hash).inserted }
        return .success(OpenRouterKeyPage(keys: keys, entryCount: payload.data.count))
    }

    /// The keys on one page in `response`; see ``keyPage(_:)``.
    public static func keys(_ response: HTTP.Response) -> Result<[OpenRouterKey], OpenRouterProblem> {
        keyPage(response).map(\.keys)
    }

    /// The key in `response`; ``OpenRouterProblem/keyNotFound`` when the account doesn't have it.
    public static func key(_ response: HTTP.Response) -> Result<OpenRouterKey, OpenRouterProblem> {
        if response.status == 404 { return .failure(.keyNotFound) }
        if let problem = problem(in: response, sizeLimit: accountSizeLimit) { return .failure(problem) }
        guard let payload = try? JSONDecoder().decode(ObjectPayload<KeyPayload>.self, from: response.body),
            let key = payload.data.key
        else { return .failure(.unreadable) }
        return .success(key)
    }

    /// What OpenRouter says about the key that made the request.
    public static func keyCheck(_ response: HTTP.Response) -> Result<OpenRouterKeyCheck, OpenRouterProblem> {
        if let problem = problem(in: response, sizeLimit: accountSizeLimit) { return .failure(problem) }
        guard let payload = try? JSONDecoder().decode(ObjectPayload<KeyCheckPayload>.self, from: response.body)
        else { return .failure(.unreadable) }
        return .success(OpenRouterKeyCheck(isManagementKey: payload.data.isManagementKey, label: payload.data.label))
    }

    /// When to try again after `problem`: honoring `Retry-After` when OpenRouter sent it, backing off from passing
    /// trouble, and not on its own at all when only a change can help.
    public static func retryAdvice(
        for problem: OpenRouterProblem, headers: [String: String] = [:], now: Date
    ) -> RetryAdvice {
        switch problem {
        case .rateLimited, .unavailable:
            RetryAfter.date(in: headers, now: now).map(RetryAdvice.notBefore) ?? .backoff
        case .unreachable, .unreadable, .tooLarge, .keychain:
            .backoff
        // A deleted key doesn't come back: asking again daily would only cost requests.
        case .noKey, .invalidKey, .notPermitted, .notManagementKey, .keyNotFound, .badRequest:
            .onRequest
        }
    }

    /// What went wrong, judging by the status and size alone; `nil` for a usable answer.
    static func problem(in response: HTTP.Response, sizeLimit: Int) -> OpenRouterProblem? {
        switch response.status {
        case 200..<300:
            return response.body.count > sizeLimit ? .tooLarge : nil
        case 400: return .badRequest(message: errorMessage(in: response.body))
        case 401: return .invalidKey
        case 403: return .notPermitted
        case 429: return .rateLimited
        case 500..<600: return .unavailable(status: response.status)
        default: return .unreadable
        }
    }

    /// `{"error": {"message": "…"}}`, OpenRouter's explanation of an error.
    private static func errorMessage(in body: Data) -> String? {
        struct ErrorPayload: Decodable {
            struct Detail: Decodable { let message: String? }
            let error: Detail?
        }
        let message = (try? JSONDecoder().decode(ErrorPayload.self, from: body))?.error?.message
        return message.map { String($0.prefix(200)) }
    }
}

// MARK: - Payloads

/// `{"data": [ … ]}`
private struct ListPayload<Element: Decodable>: Decodable {
    let data: [Element]
}

/// `{"data": { … }}`
private struct ObjectPayload<Object: Decodable>: Decodable {
    let data: Object
}

/// An amount of money in an answer, which OpenRouter may send as a JSON number or as a decimal string. Read without
/// going through `Double`, and only when all of it is a number.
private enum ReportedAmount {
    /// Not in the answer, or `null`.
    case absent
    case amount(Decimal)
    /// There, but not a number: the answer can't be vouched for.
    case unreadable

    init(_ container: KeyedDecodingContainer<AnyCodingKey>, _ key: String) {
        let codingKey = AnyCodingKey(key)
        guard container.contains(codingKey), (try? container.decodeNil(forKey: codingKey)) == false else {
            self = .absent
            return
        }
        if let value = try? container.decode(Decimal.self, forKey: codingKey), !value.isNaN {
            self = .amount(value)
        } else if let text = try? container.decode(String.self, forKey: codingKey),
            let value = Decimal(exactText: text)
        {
            self = .amount(value)
        } else {
            self = .unreadable
        }
    }
}

/// A price, which OpenRouter lists as a decimal string, but read as a number too.
private func listedPrice(_ container: KeyedDecodingContainer<AnyCodingKey>?, _ key: String) -> OpenRouterTokenPrice {
    guard let container else { return .unknown }
    if let text = container.lenient(String.self, key) { return OpenRouterTokenPrice(listed: text) }
    if let value = container.lenient(Decimal.self, key), !value.isNaN { return OpenRouterTokenPrice(value) }
    return .unknown
}

private struct ModelPayload: Decodable {
    let model: OpenRouterModel?

    init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: AnyCodingKey.self),
            let id = container.lenient(String.self, "id"), !id.isEmpty
        else {
            model = nil
            return
        }
        let architecture = try? container.nestedContainer(
            keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("architecture"))
        let pricing = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("pricing"))
        let name = container.lenient(String.self, "name").flatMap { $0.isEmpty ? nil : $0 } ?? id
        model = OpenRouterModel(
            id: id,
            name: name,
            canonicalSlug: container.lenient(String.self, "canonical_slug"),
            created: container.lenientInt64("created").flatMap {
                $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil
            },
            contextLength: container.lenientInt64("context_length").flatMap { $0 > 0 ? Int(exactly: $0) : nil },
            inputModalities: architecture?.lenient([String].self, "input_modalities") ?? [],
            outputModalities: architecture?.lenient([String].self, "output_modalities") ?? [],
            inputPrice: listedPrice(pricing, "prompt"),
            outputPrice: listedPrice(pricing, "completion"),
            expiration: container.lenient(String.self, "expiration_date").flatMap(UTCDay.init(iso:))
        )
    }
}

private struct CreditsPayload: Decodable {
    let totalCredits: ReportedAmount
    let totalUsage: ReportedAmount

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        totalCredits = ReportedAmount(container, "total_credits")
        totalUsage = ReportedAmount(container, "total_usage")
    }
}

private struct ActivityRowPayload: Decodable {
    let day: UTCDay?
    let usage: ReportedAmount
    let byokUsage: ReportedAmount

    init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: AnyCodingKey.self) else {
            day = nil
            usage = .unreadable
            byokUsage = .unreadable
            return
        }
        day = container.lenient(String.self, "date").flatMap(UTCDay.init(iso:))
        usage = ReportedAmount(container, "usage")
        byokUsage = ReportedAmount(container, "byok_usage_inference")
    }
}

private struct KeyPayload: Decodable {
    let key: OpenRouterKey?

    init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: AnyCodingKey.self),
            let hash = container.lenient(String.self, "hash"), OpenRouterAPI.isPlausibleHash(hash)
        else {
            key = nil
            return
        }
        let name = [container.lenient(String.self, "name"), container.lenient(String.self, "label")]
            .compactMap(\.self).first { !$0.isEmpty }
        key = OpenRouterKey(
            hash: hash,
            name: name ?? String(hash.prefix(8)),
            isDisabled: container.lenient(Bool.self, "disabled") ?? false,
            expiresAt: container.lenient(String.self, "expires_at").flatMap(Date.init(iso8601:))
        )
    }
}

private struct KeyCheckPayload: Decodable {
    let isManagementKey: Bool?
    let label: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        // `is_provisioning_key` is the deprecated name of the same flag.
        isManagementKey = container.lenient(Bool.self, "is_management_key", "is_provisioning_key")
        label = container.lenient(String.self, "label")
    }
}
