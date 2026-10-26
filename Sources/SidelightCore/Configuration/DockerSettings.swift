import Foundation

/// What a Docker widget shows: which context's containers, and how many of them.
public struct DockerSettings: Codable, Hashable, Sendable {
    /// What the settings editor offers for ``rowCount``.
    public static let rowCountRange = 1...10

    /// The Docker context shown; `nil` follows the CLI's current context (`docker context use`).
    public var context: String?
    /// Stopped containers in the panel's list too; the details panel offers All either way.
    public var showsStopped = false
    /// Groups listed in the regular layout; compact lists issues only.
    public var rowCount = 5
    /// Published ports under each group in the regular layout.
    public var showsPorts = true

    public init(context: String? = nil, showsStopped: Bool = false, rowCount: Int = 5, showsPorts: Bool = true) {
        self.context = context
        self.showsStopped = showsStopped
        self.rowCount = rowCount
        self.showsPorts = showsPorts
    }

    /// Missing options take their defaults, a context that can't be read follows the current one, and a hand-edited
    /// row count is moved into the range the editor offers.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DockerSettings()
        context = (try? container.decodeIfPresent(String.self, forKey: .context)).flatMap { $0 }
            .flatMap { $0.isEmpty ? nil : $0 }
        showsStopped = container.decodeLeniently(.showsStopped, or: defaults.showsStopped)
        rowCount = container.decodeLeniently(.rowCount, or: defaults.rowCount).clamped(to: Self.rowCountRange)
        showsPorts = container.decodeLeniently(.showsPorts, or: defaults.showsPorts)
    }

    public var contextChoice: DockerContextChoice { context.map { .named($0) } ?? .current }
}

/// What the Docker service has to do for the widgets on screen and the details panel.
public struct DockerDemand: Equatable, Sendable {
    /// The contexts shown, each read once for every widget showing it.
    public var contexts: Set<DockerContextChoice> = []
    /// The context whose containers' CPU and memory are sampled: the details panel shows it.
    public var stats: DockerContextChoice?

    public init(contexts: Set<DockerContextChoice> = [], stats: DockerContextChoice? = nil) {
        self.contexts = contexts
        self.stats = stats
        if let stats { self.contexts.insert(stats) }
    }

    public var isEmpty: Bool { contexts.isEmpty }

    /// Both demands' contexts, and `other`'s stats if it samples any.
    public mutating func merge(_ other: DockerDemand) {
        contexts.formUnion(other.contexts)
        if let stats = other.stats {
            self.stats = stats
            contexts.insert(stats)
        }
    }
}

extension AppConfiguration {
    /// The contexts the Docker widgets among `widgets` show.
    public func dockerDemand(of widgets: some Sequence<WidgetInstance>) -> DockerDemand {
        var demand = DockerDemand()
        for widget in widgets {
            guard case .docker(let settings) = widget.settings else { continue }
            demand.contexts.insert(settings.contextChoice)
        }
        return demand
    }
}
