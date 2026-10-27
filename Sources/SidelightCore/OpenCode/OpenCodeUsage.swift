import Foundation

/// An OpenCode Console workspace's usage limits, as OpenCode itself shows them (its `experimental.usage.limits`
/// route): the OpenCode Go subscription's allowance, and the Console's spending budgets.
///
/// Go's allowance is three windows over the same dollar amount (https://opencode.ai/docs/go/): a rolling 5 hours
/// gets 20% of the monthly limit, a week 50%, and the subscription month all of it. Each is reported as a share used.
/// Budgets are limits a workspace sets on pay-as-you-go Zen spending, in dollars.
public struct OpenCodeUsage: Equatable, Sendable {
    /// The workspace's name, when the sign-in says.
    public var workspaceName: String?
    /// `nil` without a Go subscription (OpenCode answers 403), or when it couldn't be read.
    public var go: [OpenCodeGoWindow]?
    public var budgets: [OpenCodeBudget]
    public var fetchedAt: Date

    public init(
        workspaceName: String? = nil, go: [OpenCodeGoWindow]? = nil, budgets: [OpenCodeBudget] = [], fetchedAt: Date
    ) {
        self.workspaceName = workspaceName
        self.go = go
        self.budgets = budgets
        self.fetchedAt = fetchedAt
    }

    /// Whether Go reports one of its windows used up (`rate-limited`), whatever the percentages say.
    public var isGoLimited: Bool { go?.contains(where: \.isLimited) ?? false }
}

/// One of OpenCode Go's allowance windows.
public struct OpenCodeGoWindow: Equatable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Sendable {
        /// 5 hours, rolling: 20% of the monthly limit.
        case rolling
        /// 50% of the monthly limit.
        case weekly
        /// The subscription month.
        case monthly
    }

    public var kind: Kind
    public var window: RateLimitWindow
    /// OpenCode stopped requests in this window (`status: "rate-limited"`).
    public var isLimited: Bool

    public var id: Kind { kind }

    public init(kind: Kind, window: RateLimitWindow, isLimited: Bool = false) {
        self.kind = kind
        self.window = window
        self.isLimited = isLimited
    }
}

/// A Console budget: a dollar limit on pay-as-you-go spending, for every model or some of them.
public struct OpenCodeBudget: Equatable, Sendable, Identifiable {
    public var id: String
    public var limit: Double
    /// Spent so far: for a budget per model, by the model closest to its limit.
    public var spent: Double
    /// The models it covers by name; empty when it covers all of them.
    public var models: [String]
    public var resetsAt: Date?

    public init(id: String, limit: Double, spent: Double, models: [String] = [], resetsAt: Date? = nil) {
        self.id = id
        self.limit = limit
        self.spent = spent
        self.models = models
        self.resetsAt = resetsAt
    }

    /// The share of the limit spent, 0–100.
    public var usedPercent: Double {
        guard limit > 0 else { return spent > 0 ? 100 : 0 }
        return min(max(spent / limit * 100, 0), 100)
    }
}

// MARK: - Reading OpenCode's answers

extension OpenCodeGoWindow.Kind {
    /// How long the window lasts, for the time tick and the forecast. A month is worked out from its reset.
    func durationMinutes(resetsAt: Date?) -> Int? {
        switch self {
        case .rolling: 5 * 60
        case .weekly: 7 * 24 * 60
        case .monthly:
            resetsAt.flatMap { end in
                Calendar(identifier: .gregorian).date(byAdding: .month, value: -1, to: end)
                    .map { Int((end.timeIntervalSince($0) / 60).rounded()) }
            }
        }
    }
}

extension OpenCodeUsage {
    /// `{"usage": {"rolling": {"status", "percent", "resetsAt"}, "weekly": …, "monthly": …}}` from
    /// `/zen/go/v1/usage`. `nil` when it holds none of the windows.
    static func goWindows(from data: Data) -> [OpenCodeGoWindow]? {
        guard let root = try? JSONDecoder().decode(GoUsage.self, from: data), !root.windows.isEmpty else { return nil }
        return root.windows
    }

    /// The array of budgets from `/api/policies/current-budgets`; `nil` when it isn't one.
    static func budgets(from data: Data) -> [OpenCodeBudget]? {
        (try? JSONDecoder().decode([LenientElement<Budget>].self, from: data))?.compactMap(\.value?.budget)
    }

    private struct GoUsage: Decodable {
        var windows: [OpenCodeGoWindow] = []

        init(from decoder: any Decoder) throws {
            let root = try decoder.container(keyedBy: AnyCodingKey.self)
            let usage = try root.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("usage"))
            for kind in OpenCodeGoWindow.Kind.allCases {
                guard
                    let meter = try? usage.nestedContainer(
                        keyedBy: AnyCodingKey.self, forKey: AnyCodingKey(kind.rawValue)),
                    let percent = meter.lenientDouble("percent")
                else { continue }
                let resetsAt = OpenCodeUsage.date(meter, "resetsAt")
                windows.append(
                    OpenCodeGoWindow(
                        kind: kind,
                        window: RateLimitWindow(
                            usedPercent: min(max(percent, 0), 100), resetsAt: resetsAt,
                            durationMinutes: kind.durationMinutes(resetsAt: resetsAt)),
                        isLimited: meter.lenient(String.self, "status") == "rate-limited"))
            }
        }
    }

    /// `{"ruleID", "limitDollars", "spentDollars", "per": "set" | "model", "coverage": "all" | "models",
    /// "models": [{"name", "spentDollars"}], "resetsAt", …}`
    private struct Budget: Decodable {
        var budget: OpenCodeBudget?

        init(from decoder: any Decoder) throws {
            let root = try decoder.container(keyedBy: AnyCodingKey.self)
            guard let id = root.lenient(String.self, "ruleID", "id"),
                let limit = root.lenientDouble("limitDollars", "limit")
            else { return }
            let models =
                (try? root.decodeIfPresent([LenientElement<Model>].self, forKey: AnyCodingKey("models")))?
                .compactMap(\.value) ?? []
            var spent = root.lenientDouble("spentDollars", "spent") ?? 0
            // A limit per model holds each model to it: the one spending most is the one that stops first.
            if root.lenient(String.self, "per") == "model", let most = models.compactMap(\.spent).max() {
                spent = most
            }
            let covered = root.lenient(String.self, "coverage") == "models" ? models.map(\.name) : []
            budget = OpenCodeBudget(
                id: id, limit: limit, spent: spent, models: covered, resetsAt: OpenCodeUsage.date(root, "resetsAt"))
        }

        private struct Model: Decodable {
            var name: String
            var spent: Double?

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: AnyCodingKey.self)
                guard let name = container.lenient(String.self, "name", "modelID") else {
                    throw DecodingError.dataCorruptedError(
                        forKey: AnyCodingKey("name"), in: container, debugDescription: "A model without a name")
                }
                self.name = name
                spent = container.lenientDouble("spentDollars", "spent")
            }
        }
    }

    /// ISO 8601, with or without fractional seconds, or milliseconds since 1970.
    fileprivate static func date(_ container: KeyedDecodingContainer<AnyCodingKey>, _ key: String) -> Date? {
        if let string = container.lenient(String.self, key) {
            return Date(iso8601: string) ?? Double(string).map(Date.init(millisecondsSince1970:))
        }
        return container.lenientDouble(key).map(Date.init(millisecondsSince1970:))
    }
}
