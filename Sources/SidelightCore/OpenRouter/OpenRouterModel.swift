import Foundation

/// What OpenRouter lists as a model's price for one kind of token.
public enum OpenRouterTokenPrice: Hashable, Sendable {
    /// US dollars per token.
    case perToken(Decimal)
    /// OpenRouter's routers list `-1`: the price is whatever the model they route to charges.
    case varies
    /// Not listed, or not a price.
    case unknown

    /// From the decimal string OpenRouter lists, such as `"0.0000005"`.
    public init(listed: String?) {
        guard let listed, let value = Decimal(string: listed, locale: Locale(identifier: "en_US_POSIX")),
            !value.isNaN
        else {
            self = .unknown
            return
        }
        if value >= 0 {
            self = .perToken(value)
        } else {
            self = value == -1 ? .varies : .unknown
        }
    }

    /// US dollars per million tokens, as prices are usually compared; `nil` without a known price.
    public var perMillion: Decimal? {
        if case .perToken(let price) = self { price * 1_000_000 } else { nil }
    }
}

/// One model in OpenRouter's catalogue, with only what Sidelight shows.
public struct OpenRouterModel: Identifiable, Hashable, Sendable {
    /// What requests name it by: `anthropic/claude-haiku-5.5`, or a variant like `…:free`.
    public let id: String
    /// `Anthropic: Claude Haiku 5.5`
    public let name: String
    /// OpenRouter's permanent identifier for the model, which a display ID may be an alias of.
    public let canonicalSlug: String?
    /// When OpenRouter added it. Not when the model was released.
    public let created: Date?
    /// The context window, in tokens.
    public let contextLength: Int?
    /// What it takes and produces: `text`, `image`, `file`, `audio`, `video`, `embeddings`, and any kind
    /// OpenRouter adds later.
    public let inputModalities: [String]
    public let outputModalities: [String]
    public let inputPrice: OpenRouterTokenPrice
    public let outputPrice: OpenRouterTokenPrice
    /// The day OpenRouter announced it will retire the model; `nil` when none is announced.
    public let expiration: UTCDay?
    /// The name and ID, folded for matching a search.
    let searchKey: String

    public init(
        id: String, name: String, canonicalSlug: String? = nil, created: Date? = nil, contextLength: Int? = nil,
        inputModalities: [String] = [], outputModalities: [String] = [], inputPrice: OpenRouterTokenPrice = .unknown,
        outputPrice: OpenRouterTokenPrice = .unknown, expiration: UTCDay? = nil
    ) {
        self.id = id
        self.name = name
        self.canonicalSlug = canonicalSlug
        self.created = created
        self.contextLength = contextLength
        self.inputModalities = inputModalities
        self.outputModalities = outputModalities
        self.inputPrice = inputPrice
        self.outputPrice = outputPrice
        self.expiration = expiration
        searchKey = Self.folded(name + "\n" + id)
    }

    /// OpenRouter's free variants, whose ID ends in `:free`. A model listing zero token prices isn't necessarily
    /// free: other parts of a request may still cost.
    public var isFreeVariant: Bool { id.hasSuffix(":free") }

    /// The name without the provider before the colon: `Claude Haiku 5.5`.
    public var shortName: String {
        guard let colon = name.firstIndex(of: ":") else { return name }
        let rest = name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? name : rest
    }

    /// The ID without the provider before the slash: `claude-haiku-5.5:free`.
    public var shortID: String {
        guard let slash = id.firstIndex(of: "/") else { return id }
        let rest = id[id.index(after: slash)...]
        return rest.isEmpty ? id : String(rest)
    }

    /// The provider part of the ID: `anthropic`.
    public var provider: String? {
        id.firstIndex(of: "/").map { String(id[..<$0]) }
    }

    public func matches(_ filter: OpenRouterModelFilter) -> Bool {
        switch filter {
        case .all: true
        case .textOutput: outputModalities.contains("text")
        case .textOnly: Set(inputModalities) == ["text"] && Set(outputModalities) == ["text"]
        }
    }

    /// Whether every word of `query` is in the name or the ID, ignoring case and accents. An empty query matches.
    public func matches(query: OpenRouterSearchQuery) -> Bool {
        query.terms.allSatisfy { searchKey.contains($0) }
    }

    /// Whether OpenRouter has announced the model's retirement for a day still to come, or today.
    public func isRetiring(asOf now: Date) -> Bool {
        expiration.map { $0 >= UTCDay(now) } ?? false
    }

    /// Its page on openrouter.ai; `nil` for an ID that isn't safe to put in a link.
    public var pageURL: URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:~"))
        guard !id.isEmpty, !id.hasPrefix("/"), !id.contains(".."),
            id.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) })
        else { return nil }
        return URL(string: "https://openrouter.ai/" + id)
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// What someone typed to search the catalogue, split into words once.
public struct OpenRouterSearchQuery: Hashable, Sendable {
    let terms: [String]

    public init(_ text: String) {
        terms = OpenRouterModel.folded(text).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public var isEmpty: Bool { terms.isEmpty }
}

/// OpenRouter's whole public catalogue as fetched once, ordered every way it can be listed, so lists and searches
/// only filter it.
public struct OpenRouterCatalogue: Sendable {
    /// Every model, newest first.
    public let models: [OpenRouterModel]
    public let fetchedAt: Date
    /// Positions in ``models`` in each order.
    private let orders: [OpenRouterModelSort: [Int]]
    private let counts: [OpenRouterModelFilter: Int]

    public init(models: [OpenRouterModel], fetchedAt: Date) {
        let newestFirst = models.sorted(by: Self.isOrdered(.latestAdded))
        self.models = newestFirst
        self.fetchedAt = fetchedAt
        var orders: [OpenRouterModelSort: [Int]] = [:]
        for sort in OpenRouterModelSort.allCases {
            guard sort != .latestAdded else {
                orders[sort] = Array(newestFirst.indices)
                continue
            }
            let isOrdered = Self.isOrdered(sort)
            orders[sort] = newestFirst.indices.sorted { isOrdered(newestFirst[$0], newestFirst[$1]) }
        }
        self.orders = orders
        counts = Dictionary(
            uniqueKeysWithValues: OpenRouterModelFilter.allCases.map { filter in
                (filter, newestFirst.count { $0.matches(filter) })
            })
    }

    /// How many models pass `filter`.
    public func count(_ filter: OpenRouterModelFilter) -> Int {
        counts[filter] ?? 0
    }

    /// The models passing `filter` and matching `query`, in `sort` order: the first `limit`, or all of them.
    public func models(
        _ filter: OpenRouterModelFilter, sortedBy sort: OpenRouterModelSort,
        matching query: OpenRouterSearchQuery = OpenRouterSearchQuery(""), limit: Int? = nil
    ) -> [OpenRouterModel] {
        var result: [OpenRouterModel] = []
        for index in orders[sort] ?? Array(models.indices) {
            if let limit, result.count >= limit { break }
            let model = models[index]
            if model.matches(filter) && model.matches(query: query) { result.append(model) }
        }
        return result
    }

    /// The model OpenRouter added last among those passing `filter`.
    public func newest(_ filter: OpenRouterModelFilter) -> OpenRouterModel? {
        models.first { $0.matches(filter) }
    }

    /// `sort`'s order. Ties, and models missing what's sorted by, fall back to the ID, so the order is the same on
    /// every fetch. Unknown prices and sizes go last, never first.
    static func isOrdered(_ sort: OpenRouterModelSort) -> (OpenRouterModel, OpenRouterModel) -> Bool {
        switch sort {
        case .latestAdded:
            return { lhs, rhs in
                ordered(lhs.created, rhs.created, ascending: false) ?? (lhs.id < rhs.id)
            }
        case .name:
            return { lhs, rhs in
                switch lhs.name.localizedStandardCompare(rhs.name) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: lhs.id < rhs.id
                }
            }
        case .context:
            return { lhs, rhs in
                ordered(lhs.contextLength, rhs.contextLength, ascending: false) ?? (lhs.id < rhs.id)
            }
        case .inputPrice:
            return { lhs, rhs in
                ordered(lhs.inputPrice.perMillion, rhs.inputPrice.perMillion, ascending: true) ?? (lhs.id < rhs.id)
            }
        case .outputPrice:
            return { lhs, rhs in
                ordered(lhs.outputPrice.perMillion, rhs.outputPrice.perMillion, ascending: true) ?? (lhs.id < rhs.id)
            }
        }
    }

    /// Whether `lhs` comes first, with missing values last; `nil` when they're equal and something else decides.
    private static func ordered<Value: Comparable>(_ lhs: Value?, _ rhs: Value?, ascending: Bool) -> Bool? {
        switch (lhs, rhs) {
        case (nil, nil): nil
        case (nil, _): false
        case (_, nil): true
        case (let lhs?, let rhs?): lhs == rhs ? nil : (ascending ? lhs < rhs : lhs > rhs)
        }
    }
}
