import Foundation

/// A model in Runware's catalogue.
public struct RunwareModel: Identifiable, Hashable, Sendable {
    /// Its AIR, what requests name it by: `civitai:305149@392545`, `runware:101@1`.
    public let air: String
    /// Its name; its AIR when it has none.
    public let name: String
    public let version: String?
    /// `checkpoint`, `lora`, …, or any category Runware adds later.
    public let category: String?
    public let architecture: String?
    public let type: String?
    public let tags: [String]
    public let isPrivate: Bool
    /// Its thumbnail. Kept for later: not loaded yet.
    public let heroImage: URL?
    public let defaultWidth: Int?
    public let defaultHeight: Int?
    public let defaultSteps: Int?
    public let defaultCFG: Double?

    public init(
        air: String, name: String, version: String? = nil, category: String? = nil, architecture: String? = nil,
        type: String? = nil, tags: [String] = [], isPrivate: Bool = false, heroImage: URL? = nil,
        defaultWidth: Int? = nil, defaultHeight: Int? = nil, defaultSteps: Int? = nil, defaultCFG: Double? = nil
    ) {
        self.air = air
        self.name = name
        self.version = version
        self.category = category
        self.architecture = architecture
        self.type = type
        self.tags = tags
        self.isPrivate = isPrivate
        self.heroImage = heroImage
        self.defaultWidth = defaultWidth
        self.defaultHeight = defaultHeight
        self.defaultSteps = defaultSteps
        self.defaultCFG = defaultCFG
    }

    public var id: String { air }

    /// `{"model": "<AIR>"}`, to paste into a request.
    public var requestJSON: String {
        let data = try? JSONSerialization.data(withJSONObject: ["model": air], options: [.withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"model\": \"\(air)\"}"
    }
}

/// A search of Runware's catalogue, and which page of it. Filters are Runware's own words, so values it adds later
/// pass through.
public struct RunwareModelQuery: Hashable, Sendable {
    /// Results come this many to a page (Runware allows up to 100).
    public static let pageSize = 50

    /// Known values for ``category``, as Runware documents them.
    public static let categories = ["checkpoint", "lora", "lycoris", "vae", "embeddings"]
    /// Known values for ``source``: `featured`, not `official`, whatever older docs say.
    public static let sources = ["featured", "community"]
    /// Known values for ``visibility``.
    public static let visibilities = ["public", "owned", "private", "favorite"]

    /// Matched against names, descriptions and AIRs; empty for none.
    public var search: String
    public var category: String?
    public var source: String?
    public var visibility: String?
    public var offset = 0

    public init(
        search: String = "", category: String? = nil, source: String? = nil, visibility: String? = nil,
        offset: Int = 0
    ) {
        self.search = search
        self.category = category
        self.source = source
        self.visibility = visibility
        self.offset = offset
    }

    /// The same search, from its first page.
    public var firstPage: Self {
        var query = self
        query.offset = 0
        return query
    }

    /// Whether it searches for anything: Runware may not list its catalogue without a search.
    public var hasSearch: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// One page of search results.
public struct RunwareModelPage: Equatable, Sendable {
    /// The readable models on the page, each once.
    public let models: [RunwareModel]
    /// How many results Runware listed on the page, readable or not: where the next one starts.
    public let entryCount: Int
    /// How many models match in all; `nil` when Runware didn't say.
    public let total: Int?
    public let query: RunwareModelQuery

    public init(models: [RunwareModel], entryCount: Int? = nil, total: Int?, query: RunwareModelQuery) {
        self.models = models
        self.entryCount = entryCount ?? models.count
        self.total = total
        self.query = query
    }

    /// Where the next page starts; `nil` after a short page, or once the total is reached.
    public var nextOffset: Int? {
        let next = query.offset + entryCount
        guard entryCount >= RunwareModelQuery.pageSize else { return nil }
        if let total, next >= total { return nil }
        return next
    }
}
