import AppKit
import Observation
import SidelightCore
import SwiftUI

/// What someone is doing in the catalogue's details panel: their search, filter, order and the model they opened.
/// Starts from the list they clicked, and is forgotten when the panel closes; it never changes the widget's
/// settings.
@Observable
final class OpenRouterCatalogueBrowser {
    var search = ""
    var filter: OpenRouterModelFilter
    var sort: OpenRouterModelSort
    /// The model shown in detail, if any.
    var expandedID: OpenRouterModel.ID?

    /// The last list worked out, for the snapshot and choices it was worked out for: typing filters it once per
    /// change, not on every redraw.
    @ObservationIgnored private var cached: (key: CacheKey, models: [OpenRouterModel])?
    @ObservationIgnored private var cachedCounts: (key: CountsKey, counts: [OpenRouterModality?: Int])?

    private struct CacheKey: Equatable {
        let fetchedAt: Date
        let count: Int
        let filter: OpenRouterModelFilter
        let sort: OpenRouterModelSort
        let query: OpenRouterSearchQuery
    }

    private struct CountsKey: Equatable {
        let fetchedAt: Date
        let count: Int
        /// Only the inputs and exactness count: each output is counted.
        let filter: OpenRouterModelFilter
        let query: OpenRouterSearchQuery
    }

    init(filter: OpenRouterModelFilter, sort: OpenRouterModelSort) {
        self.filter = filter
        self.sort = sort
    }

    /// The models to list from `catalogue`.
    func models(in catalogue: OpenRouterCatalogue) -> [OpenRouterModel] {
        let key = CacheKey(
            fetchedAt: catalogue.fetchedAt, count: catalogue.models.count, filter: filter, sort: sort,
            query: OpenRouterSearchQuery(search))
        if let cached, cached.key == key { return cached.models }
        let models = catalogue.models(filter, sortedBy: sort, matching: key.query)
        cached = (key, models)
        return models
    }

    /// How many models in `catalogue` match the search and the chosen inputs for each output, and for any output
    /// under `nil`: the output tabs say where the matches are.
    func outputCounts(in catalogue: OpenRouterCatalogue) -> [OpenRouterModality?: Int] {
        let key = CountsKey(
            fetchedAt: catalogue.fetchedAt, count: catalogue.models.count, filter: filter.producing(nil),
            query: OpenRouterSearchQuery(search))
        if let cachedCounts, cachedCounts.key == key { return cachedCounts.counts }
        let matches = catalogue.models.filter { $0.matches(query: key.query) }
        var counts: [OpenRouterModality?: Int] = [:]
        for output in [nil] + catalogue.outputs {
            let filter = key.filter.producing(output)
            counts[output] = matches.count { $0.matches(filter) }
        }
        cachedCounts = (key, counts)
        return counts
    }
}

/// Every OpenRouter model, in the details panel: search by name or ID, filter, order, and open one to see all of it.
/// It opens on the catalogue already fetched; a stale one syncs in the background, and rows keep their place.
struct OpenRouterCatalogueView: View {
    let browser: OpenRouterCatalogueBrowser
    @Environment(OpenRouterService.self) private var service
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let resource = service.catalogue
        VStack(alignment: .leading, spacing: 0) {
            controls(resource)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            HairlineDivider()
            WidgetClock { now in
                list(resource, now: now)
            }
        }
        .defaultFocus($isSearchFocused, true)
        .onAppear { isSearchFocused = true }
    }

    // MARK: Controls

    private func controls(_ resource: RemoteResource<OpenRouterCatalogue, OpenRouterProblem>) -> some View {
        @Bindable var browser = browser
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search by name or ID", text: $browser.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($isSearchFocused)
                    .accessibilityLabel("Search models")
                if !browser.search.isEmpty {
                    Button {
                        browser.search = ""
                        isSearchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear the search")
                    .accessibilityLabel("Clear the search")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))

            if let catalogue = resource.value {
                OpenRouterOutputTabs(
                    output: $browser.filter.output.animation(Motion.snappy), outputs: catalogue.outputs,
                    counts: browser.outputCounts(in: catalogue))
            }

            HStack(spacing: 10) {
                Menu {
                    Picker("Order", selection: $browser.sort) {
                        ForEach(OpenRouterModelSort.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(browser.sort.title, systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 11))
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Order")
                OpenRouterInputsMenu(
                    filter: $browser.filter.animation(Motion.snappy), inputs: resource.value?.inputs ?? [])
                Spacer(minLength: 4)
                if let catalogue = resource.value {
                    WidgetClock { now in
                        OpenRouterSyncLabel(
                            state: OpenRouterSyncState(
                                syncedAt: catalogue.fetchedAt, problem: resource.problem,
                                isFetching: resource.isFetching, refresh: service.refreshCatalogue),
                            now: now, size: 10.5)
                    }
                }
            }
        }
    }

    // MARK: List

    @ViewBuilder
    private func list(
        _ resource: RemoteResource<OpenRouterCatalogue, OpenRouterProblem>, now: Date
    ) -> some View {
        if let catalogue = resource.value {
            let models = browser.models(in: catalogue)
            if models.isEmpty {
                emptyState(
                    browser.search.isEmpty ? "No models like that" : "No matches",
                    detail: browser.search.isEmpty
                        ? "Try another filter." : "Nothing called “\(browser.search)” \(scopeHint).")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(models) { model in
                            OpenRouterCatalogueRow(
                                model: model, isExpanded: browser.expandedID == model.id, now: now
                            ) {
                                withAnimation(Motion.snappy) {
                                    browser.expandedID = browser.expandedID == model.id ? nil : model.id
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.automatic)
            }
        } else if let problem = resource.problem {
            VStack(alignment: .leading, spacing: 8) {
                emptyState("Catalogue unavailable", detail: "\(problem.title). \(problem.advice)")
                Button(resource.isFetching ? "Trying…" : "Try Again") { service.refreshCatalogue() }
                    .controlSize(.small)
                    .disabled(resource.isFetching)
                    .padding(.horizontal, 16)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading models…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    /// `in text-output models`, so a search that finds nothing says where it looked.
    private var scopeHint: String {
        browser.filter.isAll ? "in any model" : "among these models"
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12.5, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What models produce, as OpenRouter's catalogue tabs them: every output with how many models produce it (matching
/// the search and inputs, if any), wrapping onto more lines rather than scrolling sideways. One with nothing to show
/// is dimmed but stays choosable.
private struct OpenRouterOutputTabs: View {
    @Binding var output: OpenRouterModality?
    let outputs: [OpenRouterModality]
    let counts: [OpenRouterModality?: Int]

    var body: some View {
        FlowLayout(spacing: 5, lineSpacing: 5) {
            tab(nil, title: "All", systemImage: nil)
            ForEach(outputs) { tab($0, title: $0.title, systemImage: $0.systemImage) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Produces")
    }

    private func tab(_ candidate: OpenRouterModality?, title: String, systemImage: String?) -> some View {
        let isSelected = output == candidate
        let count = counts[candidate] ?? 0
        return Button {
            output = candidate
        } label: {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9.5, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(count, format: .number)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .opacity(isSelected ? 0.8 : 0.55)
                    .contentTransition(.numericText(value: Double(count)))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07)))
            .foregroundStyle(isSelected ? .white : .primary)
            .opacity(count == 0 && !isSelected ? 0.45 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(candidate.map { "Models that produce \($0.title.lowercased())" } ?? "Every model")
        .accessibilityLabel(title)
        .accessibilityValue("\(count) models")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// What the models must read, as OpenRouter's input checkboxes: each input ticked narrows the list to models that
/// read it, among others, or with "Nothing else", only those.
private struct OpenRouterInputsMenu: View {
    @Binding var filter: OpenRouterModelFilter
    /// The inputs the catalogue lists.
    let inputs: [OpenRouterModality]

    var body: some View {
        Menu {
            ForEach(
                OpenRouterModality.ordered(
                    OpenRouterModality.knownInputs + inputs + filter.inputs, as: OpenRouterModality.knownInputs)
            ) { input in
                Toggle(isOn: reads(input)) {
                    Label(input.title, systemImage: input.systemImage)
                }
            }
            Divider()
            Toggle("Nothing Else", isOn: $filter.isExact)
                .disabled(filter.isAll)
            if !filter.inputs.isEmpty || filter.isExact {
                Button("Any Input") {
                    filter.inputs = []
                    filter.isExact = false
                }
            }
        } label: {
            Label(title, systemImage: "line.3.horizontal.decrease")
                .font(.system(size: 11))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(filter.explanation)
    }

    /// `Any input`, `Reads image, file`, `Reads text only`.
    private var title: String {
        guard !filter.inputs.isEmpty else { return filter.isExact ? "Any input · only" : "Any input" }
        return "Reads \(filter.inputList)\(filter.isExact ? " only" : "")"
    }

    private func reads(_ input: OpenRouterModality) -> Binding<Bool> {
        Binding {
            filter.inputs.contains(input)
        } set: { isOn in
            if isOn { filter.inputs.insert(input) } else { filter.inputs.remove(input) }
        }
    }
}

/// Lays its views out in rows, left to right, starting a new row when one is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let added = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if added > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// One model in the catalogue: a standard row that opens in place to everything about it.
private struct OpenRouterCatalogueRow: View {
    let model: OpenRouterModel
    let isExpanded: Bool
    let now: Date
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                OpenRouterModelSummary(
                    model: model, density: .standard, showsRetiring: true, isCompact: false, now: now
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hides the details" : "Shows the details")
            .accessibilityAddTraits(isExpanded ? .isSelected : [])
            if isExpanded {
                OpenRouterModelDetail(model: model, now: now)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(isExpanded ? 0.07 : 0))
        )
        .hoverHighlight(isEnabled: !isExpanded, cornerRadius: 9, opacity: 0.05, vertical: 0)
        .contextMenu { OpenRouterModelMenu(model: model) }
    }
}

/// Everything Sidelight knows about a model: its context, what it reads and writes, its prices, its retirement date,
/// and a link to its page.
private struct OpenRouterModelDetail: View {
    let model: OpenRouterModel
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("ID", model.id, monospaced: true)
            if let slug = model.canonicalSlug, slug != model.id {
                row("Permanent ID", slug, monospaced: true)
            }
            if let context = model.contextLength {
                row("Context", "\(context.formatted()) tokens")
            }
            row("Reads → writes", OpenRouterFormat.modalities(of: model))
            row(
                "Per million tokens",
                "\(OpenRouterFormat.pricePerMillion(model.inputPrice)) input · "
                    + "\(OpenRouterFormat.pricePerMillion(model.outputPrice)) output")
            if let created = model.created {
                row("Added", created.formatted(date: .abbreviated, time: .omitted))
            }
            if let expiration = model.expiration {
                row(model.isRetiring(asOf: now) ? "Retiring" : "Retired", OpenRouterFormat.longDay(expiration))
            }
            HStack(spacing: 6) {
                if model.isFreeVariant { OpenRouterBadge(title: "Free", color: .green) }
                if model.inputPrice == .varies || model.outputPrice == .varies {
                    OpenRouterBadge(title: "Price varies by routed model", color: .secondary)
                }
            }
            HStack(spacing: 12) {
                if let url = model.pageURL {
                    Button("Open on openrouter.ai", systemImage: "arrow.up.forward.app") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Copy ID", systemImage: "doc.on.doc") { SessionHost.copy(model.id) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .padding(.top, 2)
            Text(Self.priceNote)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private static let priceNote =
        "Prices are the top provider's, per token type; requests may cost more for images, search or long prompts."

    private func row(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 98, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
