import Foundation

/// Client side of the `codex app-server` JSON-RPC protocol (newline-delimited JSON over stdio).
///
/// Pure state: it builds request lines and turns response lines into ``Message``s; the caller owns the process.
/// Only **read-only** methods are exposed on purpose — never add `account/rateLimitResetCredit/consume`,
/// login/logout or thread/turn methods here.
public struct CodexAppServerSession: Sendable {
    public enum Method: String, CaseIterable, Sendable {
        case readAccount = "account/read"
        case readRateLimits = "account/rateLimits/read"
        case readUsage = "account/usage/read"
    }

    public enum Message: Equatable, Sendable {
        /// Response to ``Method/readAccount``.
        case account(CodexAccount)
        /// Response to ``Method/readRateLimits``.
        case rateLimits(CodexRateLimitsReading)
        /// Response to ``Method/readUsage``.
        case usage(CodexUsage)
        /// An error response to one of our requests, such as reading rate limits while signed out.
        case failed(Method, message: String)
        /// `account/rateLimits/updated` notification: sparse, so merge it into what's known
        /// (``CodexRateLimits/merging(_:)``).
        case rateLimitsUpdated(CodexRateLimits)
        /// `account/updated` notification: the sign-in or plan changed. Its plan, when it has one.
        case accountUpdated(plan: String?)
    }

    private var nextRequestID = 10
    private var pendingRequests: [Int: Method] = [:]

    public init() {}

    /// The `initialize` request followed by the `initialized` notification.
    public static func handshake(clientName: String, clientVersion: String) -> [Data] {
        let clientInfo = ["name": clientName, "version": clientVersion]
        return [
            encode(Request(id: 1, method: "initialize", params: ["clientInfo": clientInfo])),
            encode(Request<NoParams>(id: nil, method: "initialized", params: nil)),
        ]
    }

    public mutating func request(_ method: Method) -> Data {
        nextRequestID += 1
        pendingRequests[nextRequestID] = method
        // `account/read` requires its params object; an empty one doesn't ask for a token refresh.
        let params: NoParams? = method == .readAccount ? NoParams() : nil
        return Self.encode(Request(id: nextRequestID, method: method.rawValue, params: params))
    }

    /// Decodes one line of server output. Returns `nil` for anything we don't care about.
    public mutating func decode(_ line: Data) -> Message? {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: line) else { return nil }

        if let id = envelope.id {
            guard let method = pendingRequests.removeValue(forKey: id) else { return nil }
            if let error = envelope.error {
                return .failed(method, message: error.message ?? "Error \(error.code ?? 0)")
            }
            switch method {
            case .readAccount:
                return (try? decoder.decode(Response<AccountResult>.self, from: line)).map {
                    .account($0.result.account)
                }
            case .readRateLimits:
                guard let result = try? decoder.decode(Response<RateLimitsResult>.self, from: line).result,
                    let rateLimits = result.rateLimits
                else { return nil }
                return .rateLimits(
                    CodexRateLimitsReading(
                        rateLimits: rateLimits,
                        resetCredits: result.resetCredits,
                        ordinaryUsageAllowed: result.ordinaryUsageAllowed
                    )
                )
            case .readUsage:
                guard let result = try? decoder.decode(Response<UsageResult>.self, from: line).result else {
                    return nil
                }
                return .usage(result.usage)
            }
        }

        switch envelope.method {
        case "account/rateLimits/updated":
            guard let params = try? decoder.decode(Notification<RateLimitsResult>.self, from: line).params,
                let rateLimits = params.rateLimits
            else { return nil }
            return .rateLimitsUpdated(rateLimits)
        case "account/updated":
            let params = try? decoder.decode(Notification<AccountUpdatedParams>.self, from: line).params
            return .accountUpdated(plan: params?.planType)
        default:
            return nil
        }
    }

    // MARK: Wire format

    private struct Request<Params: Encodable>: Encodable {
        var jsonrpc = "2.0"
        var id: Int?
        var method: String
        var params: Params?
    }

    private struct NoParams: Encodable {}

    private static func encode(_ request: some Encodable) -> Data {
        // Encoding plain strings and dictionaries of strings can't fail.
        var data = (try? JSONEncoder().encode(request)) ?? Data()
        data.append(0x0A)
        return data
    }

    private struct Envelope: Decodable {
        var id: Int?
        var method: String?
        var error: ErrorBody?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            id = container.lenient(Int.self, "id")
            method = container.lenient(String.self, "method")
            error = container.lenient(ErrorBody.self, "error")
        }
    }

    private struct ErrorBody: Decodable {
        var code: Int64?
        var message: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            code = container.lenientInt64("code")
            message = container.lenient(String.self, "message")
        }
    }

    private struct Response<Result: Decodable>: Decodable {
        var result: Result
    }

    private struct Notification<Params: Decodable>: Decodable {
        var params: Params
    }

    private struct RateLimitsResult: Decodable {
        var rateLimits: CodexRateLimits?
        var resetCredits: Int?
        var ordinaryUsageAllowed: Bool?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            rateLimits = container.lenient(CodexRateLimits.self, "rateLimits")
            resetCredits = container.lenient(ResetCredits.self, "rateLimitResetCredits")?.availableCount
            ordinaryUsageAllowed = container.lenient(Bool.self, "ordinaryUsageAllowed")
        }
    }

    private struct ResetCredits: Decodable {
        var availableCount: Int?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            availableCount = container.lenientInt64("availableCount").map(Int.init)
        }
    }

    private struct UsageResult: Decodable {
        var usage: CodexUsage

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            let lifetimeTokens = container.lenient(Summary.self, "summary")?.lifetimeTokens
            let buckets = container.lenient([Bucket].self, "dailyUsageBuckets") ?? []
            var tokensByDay: [String: Int64] = [:]
            for bucket in buckets {
                if let day = bucket.startDate, let tokens = bucket.tokens { tokensByDay[day] = tokens }
            }
            usage = CodexUsage(lifetimeTokens: lifetimeTokens, tokensByDay: tokensByDay)
        }

        struct Summary: Decodable {
            var lifetimeTokens: Int64?

            init(from decoder: any Decoder) throws {
                lifetimeTokens = try decoder.container(keyedBy: AnyCodingKey.self).lenientInt64("lifetimeTokens")
            }
        }

        struct Bucket: Decodable {
            var startDate: String?
            var tokens: Int64?

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: AnyCodingKey.self)
                startDate = container.lenient(String.self, "startDate")
                tokens = container.lenientInt64("tokens")
            }
        }
    }

    private struct AccountUpdatedParams: Decodable {
        var planType: String?

        init(from decoder: any Decoder) throws {
            planType = try decoder.container(keyedBy: AnyCodingKey.self).lenient(String.self, "planType")
        }
    }

    private struct AccountResult: Decodable {
        var account: CodexAccount

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            guard let details = container.lenient(AccountDetails.self, "account") else {
                // No account: signed out, unless the configured provider needs no OpenAI sign-in at all.
                account = container.lenient(Bool.self, "requiresOpenaiAuth") == false ? .otherProvider : .signedOut
                return
            }
            account =
                switch details.type {
                case "chatgpt": .chatGPT(plan: details.planType)
                case "apiKey": .apiKey
                default: .otherProvider
                }
        }

        struct AccountDetails: Decodable {
            var type: String?
            var planType: String?

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: AnyCodingKey.self)
                type = container.lenient(String.self, "type")
                planType = container.lenient(String.self, "planType")
            }
        }
    }
}
