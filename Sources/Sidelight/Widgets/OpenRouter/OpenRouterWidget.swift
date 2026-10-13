import AppKit
import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let openRouter = WidgetMetadata(
        title: "OpenRouter",
        systemImage: "sparkles.rectangle.stack.fill",
        tint: .indigo,
        summary: "New models, balances and spending",
        details: "The newest models on OpenRouter, or any list of them, and your accounts' balances and spending. "
            + "Built from blocks. Only balances need a key.",
        isBeta: true
    )
}

extension OpenRouterSettings {
    /// The Widgets window's one-line description. Not ``summary``, the Summary block's options.
    var layoutSummary: String {
        if let preset { return "\(preset.title) · \(syncSummary)" }
        let lists = shownLists.count
        let balances = shownBalances.count
        var parts: [String] = []
        if balances > 0 { parts.append(balances == 1 ? "1 balance" : "\(balances) balances") }
        if lists > 0 { parts.append(lists == 1 ? "1 list" : "\(lists) lists") }
        if parts.isEmpty { parts.append(blocks.isShown(.summary) ? "Summary" : "No blocks") }
        if showsCatalogue { parts.append(syncSummary) }
        return parts.joined(separator: " · ")
    }

    private var syncSummary: String {
        sync.minutes.map(OpenRouterSettings.syncTitle) ?? "Synced manually"
    }

    /// `Every 15 minutes`, `Every hour`, `Every 6 hours`, `Every day`.
    static func syncTitle(minutes: Int) -> String {
        if minutes % 1440 == 0 {
            let days = minutes / 1440
            return days == 1 ? "Every day" : "Every \(days) days"
        }
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "Every hour" : "Every \(hours) hours"
        }
        return "Every \(minutes) minutes"
    }
}

// MARK: - Widget

struct OpenRouterWidgetView: View {
    let settings: OpenRouterSettings
    let layout: WidgetLayout
    @Environment(OpenRouterService.self) private var service
    @Environment(DetailsPresenter.self) private var details
    @Environment(\.widgetPlacement) private var placement
    @Environment(\.isWidgetPreview) private var isPreview

    var body: some View {
        WidgetClock { now in
            switch layout {
            case .regular, .compact: blocks(now: now)
            case .minimal, .bar: glance(now: now)
            }
        }
    }

    /// The catalogue to show: the one fetched, or in the Widgets window and the builder, until a widget that's been
    /// added has fetched it, a few models as OpenRouter listed them.
    private func catalogue(now: Date) -> OpenRouterCatalogue? {
        service.catalogue.value ?? (isPreview ? .sample(at: now) : nil)
    }

    /// The account a Balance block reads. Previews read none: they show an example.
    private func account(_ id: UUID, _ options: OpenRouterBalanceOptions) -> OpenRouterAccount? {
        guard let placement else { return nil }
        return service.account(options.account(widget: placement.widgetID, block: id))
    }

    // MARK: Blocks

    @ViewBuilder
    private func blocks(now: Date) -> some View {
        let catalogue = catalogue(now: now)
        let blocks = shownBlocks(hasCatalogue: catalogue != nil)
        if blocks.isEmpty {
            WidgetMessage(
                title: "No blocks shown", detail: "Choose blocks in this widget's builder.",
                systemImage: "square.stack.3d.up", layout: layout)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.element) { index, block in
                    if index > 0 {
                        HairlineDivider()
                            .padding(.vertical, layout == .regular ? 10 : 7)
                    }
                    view(for: block, catalogue: catalogue, now: now)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(Motion.layout, value: blocks)
        }
    }

    /// The blocks to draw. Without a catalogue, the first block that shows models says why, once, for all of them.
    private func shownBlocks(hasCatalogue: Bool) -> [OpenRouterBlock] {
        let blocks = settings.blocks.shownBlocks
        guard !hasCatalogue else { return blocks }
        let first = blocks.first(where: \.showsCatalogue)
        return blocks.filter { !$0.showsCatalogue || $0 == first }
    }

    @ViewBuilder
    private func view(for block: OpenRouterBlock, catalogue: OpenRouterCatalogue?, now: Date) -> some View {
        switch block {
        case .balance(let id):
            let options = settings.balanceOptions(id)
            OpenRouterBalanceBlock(options: options, account: account(id, options), layout: layout, now: now)
        case .summary, .list:
            if let catalogue {
                OpenRouterCatalogueBlocks(
                    catalogue: catalogue, settings: settings, layout: layout, now: now, sync: sync(catalogue),
                    open: open
                )
                .view(for: block)
            } else {
                catalogueMessage
            }
        }
    }

    /// Why there are no models to show yet.
    @ViewBuilder
    private var catalogueMessage: some View {
        let resource = service.catalogue
        if let problem = resource.problem {
            WidgetMessage(
                title: "Catalogue unavailable", detail: "\(problem.title). \(problem.advice)",
                systemImage: "exclamationmark.triangle", layout: layout,
                action: WidgetMessage.Action(title: "Try Again", isDisabled: resource.isFetching) {
                    service.refreshCatalogue()
                })
        } else {
            WidgetMessage(title: "Loading models…", detail: nil, systemImage: "hourglass", layout: layout)
        }
    }

    /// When the catalogue was synced, and how to sync it now; previews never fetch.
    private func sync(_ catalogue: OpenRouterCatalogue) -> OpenRouterSyncState {
        let resource = service.catalogue
        return isPreview
            ? OpenRouterSyncState(syncedAt: catalogue.fetchedAt, problem: nil, isFetching: false, refresh: nil)
            : OpenRouterSyncState(
                syncedAt: catalogue.fetchedAt, problem: resource.problem, isFetching: resource.isFetching,
                refresh: service.refreshCatalogue)
    }

    /// Opens the whole catalogue in the details panel, in place of this panel. Only from a real panel: previews
    /// have no placement.
    private var open: ((DetailsRequest) -> Void)? {
        guard let placement, !isPreview else { return nil }
        return { [details] request in details.open(request, from: placement) }
    }

    // MARK: Glance

    @ViewBuilder
    private func glance(now: Date) -> some View {
        switch settings.resolvedGlance {
        case .balance:
            if let (id, options) = settings.glanceBalance {
                OpenRouterBalanceBlock(options: options, account: account(id, options), layout: layout, now: now)
            } else {
                WidgetMessage(
                    title: "No Balance block", detail: "Add one in this widget's builder, or show a model instead.",
                    systemImage: "creditcard", layout: layout)
            }
        case .automatic, .newest, .count:
            if let catalogue = catalogue(now: now) {
                OpenRouterCatalogueBlocks(
                    catalogue: catalogue, settings: settings, layout: layout, now: now, sync: sync(catalogue),
                    open: open
                )
                .glance
            } else {
                catalogueMessage
            }
        }
    }
}

/// The blocks and glances that show the model catalogue, for one catalogue.
private struct OpenRouterCatalogueBlocks {
    let catalogue: OpenRouterCatalogue
    let settings: OpenRouterSettings
    let layout: WidgetLayout
    let now: Date
    let sync: OpenRouterSyncState
    /// `nil` where no details panel can open: previews.
    let open: ((DetailsRequest) -> Void)?

    /// Why the last sync failed, while showing an older catalogue.
    private var problem: OpenRouterProblem? { sync.problem }

    /// Without the summary, the first list carries the refresh button.
    private var firstListShowingRefresh: OpenRouterBlock? {
        guard !settings.blocks.isShown(.summary) else { return nil }
        return settings.shownLists.first.map { .list($0.id) }
    }

    @ViewBuilder
    func view(for block: OpenRouterBlock) -> some View {
        let isCompact = layout == .compact
        switch block {
        case .summary:
            OpenRouterSummaryBlock(
                count: catalogue.count(settings.summary.filter), filter: settings.summary.filter, sync: sync,
                isCompact: isCompact, now: now)
        case .list(let id):
            let options = settings.listOptions(id)
            let rows = isCompact ? min(options.maximumRows, 5) : options.maximumRows
            let request = DetailsRequest.openRouterModels(filter: options.filter, sort: options.sort)
            let openList: (() -> Void)? = open.map { open in { open(request) } }
            OpenRouterModelListBlock(
                title: options.title,
                models: catalogue.models(options.filter, sortedBy: options.sort, limit: rows),
                total: catalogue.count(options.filter), options: options, isCompact: isCompact, now: now,
                sync: block == firstListShowingRefresh ? sync : nil, open: openList)
        case .balance:
            EmptyView()
        }
    }

    // MARK: Glance

    @ViewBuilder
    var glance: some View {
        let filter = settings.glanceFilter
        let request = DetailsRequest.openRouterModels(filter: filter, sort: .latestAdded)
        let content = Group {
            switch settings.resolvedGlance {
            case .count: countGlance(catalogue.count(filter))
            case .automatic, .newest, .balance: newestGlance(catalogue.newest(filter))
            }
        }
        .opacity(problem == nil ? 1 : 0.6)
        if let open {
            content
                .opens { open(request) }
                .help(glanceHelp + "\nClick to see every model.")
        } else {
            content.help(glanceHelp)
        }
    }

    @ViewBuilder
    private func newestGlance(_ model: OpenRouterModel?) -> some View {
        let name = model?.shortName ?? "No models"
        if layout == .bar {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                Text(name)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 170, alignment: .leading)
                if let created = model?.created {
                    Text(Formatting.shortAge(since: created, now: now))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(spacing: 2) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.system(size: 9.5, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
        }
    }

    @ViewBuilder
    private func countGlance(_ count: Int) -> some View {
        if layout == .bar {
            HStack(spacing: 5) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
                Text("\(count)").font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("models").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 0) {
                Text("\(count)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                Text("models").font(.system(size: 8.5)).foregroundStyle(.secondary)
            }
        }
    }

    private var glanceHelp: String {
        let filter = settings.glanceFilter
        var lines: [String] = []
        if let newest = catalogue.newest(filter) {
            lines.append("Newest on OpenRouter: \(newest.name)")
        }
        lines.append(filter.count(catalogue.count(filter)))
        lines.append("Synced \(UsageFormat.age(of: catalogue.fetchedAt, now: now))")
        if let problem { lines.append("\(problem.title). \(problem.advice)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Blocks

/// When the catalogue was synced, and how to sync it now, for whichever block shows it.
struct OpenRouterSyncState {
    let syncedAt: Date
    /// Why the last sync failed, while an older catalogue shows.
    let problem: OpenRouterProblem?
    let isFetching: Bool
    /// `nil` in previews, which never fetch.
    let refresh: (() -> Void)?
}

/// `synced 12m ago ⟳`
struct OpenRouterSyncLabel: View {
    let state: OpenRouterSyncState
    let now: Date
    let size: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text(caption)
                .font(.system(size: size))
                .foregroundStyle(state.problem == nil ? Color.secondary : .orange)
                .lineLimit(1)
            if let refresh = state.refresh {
                OpenRouterRefreshButton(isFetching: state.isFetching, help: "Sync the catalogue now", action: refresh)
            }
        }
        .help(state.problem.map { "\($0.title). \($0.advice)" } ?? "")
    }

    private var caption: String {
        let age = UsageFormat.age(of: state.syncedAt, now: now)
        guard let problem = state.problem else { return "synced \(age)" }
        return "\(problem.title) · synced \(age)"
    }
}

/// `662 models · synced 12m ago ⟳`
private struct OpenRouterSummaryBlock: View {
    let count: Int
    let filter: OpenRouterModelFilter
    let sync: OpenRouterSyncState
    let isCompact: Bool
    let now: Date

    var body: some View {
        if isCompact {
            VStack(alignment: .leading, spacing: 1) {
                Text(filter.count(count))
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                OpenRouterSyncLabel(state: sync, now: now, size: 9.5)
            }
        } else {
            HStack(alignment: .center, spacing: 6) {
                Text(filter.count(count))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 2)
                OpenRouterSyncLabel(state: sync, now: now, size: 10)
            }
        }
    }
}

/// A list of models, and a way to see them all.
private struct OpenRouterModelListBlock: View {
    let title: String?
    let models: [OpenRouterModel]
    /// How many models pass the list's filter.
    let total: Int
    let options: OpenRouterModelListOptions
    let isCompact: Bool
    let now: Date
    /// The sync time and refresh button, for the first list when the summary is hidden.
    let sync: OpenRouterSyncState?
    /// `nil` in previews, where no details panel can open.
    let open: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 5 : 7) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if models.isEmpty {
                Text("No models")
                    .font(.system(size: isCompact ? 10 : 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(models) { model in
                OpenRouterModelRow(
                    model: model, density: isCompact ? .lean : options.density,
                    showsRetiring: options.showsRetiring, isCompact: isCompact, now: now)
            }
            footer
        }
        .animation(Motion.gentle, value: models.map(\.id))
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                open?()
            } label: {
                HStack(spacing: 3) {
                    Text("View all \(total)")
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    Spacer(minLength: 0)
                }
                .font(.system(size: isCompact ? 9.5 : 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(open == nil)
            .hoverHighlight(isEnabled: open != nil, vertical: 1)
            .help(open == nil ? "Opens from the panel" : "See every model, searchable, in place of the panel")
            if let sync {
                OpenRouterSyncLabel(state: sync, now: now, size: isCompact ? 9.5 : 10)
            }
        }
    }
}

/// One model: its name and when it was added, then its ID and prices, then its context, what it takes and makes, and
/// badges, as `density` asks. A click opens its page on openrouter.ai.
struct OpenRouterModelRow: View {
    let model: OpenRouterModel
    let density: OpenRouterRowDensity
    let showsRetiring: Bool
    let isCompact: Bool
    let now: Date

    var body: some View {
        Button {
            if let url = model.pageURL { NSWorkspace.shared.open(url) }
        } label: {
            OpenRouterModelSummary(
                model: model, density: density, showsRetiring: showsRetiring, isCompact: isCompact, now: now
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight(isEnabled: model.pageURL != nil, vertical: isCompact ? 2 : 3)
        .contextMenu { OpenRouterModelMenu(model: model) }
        .help("\(model.name)\n\(model.id)")
        .accessibilityHint(model.pageURL == nil ? "" : "Opens the model on openrouter.ai")
    }
}

/// What a model row shows, for the widget's rows and the details panel's.
struct OpenRouterModelSummary: View {
    let model: OpenRouterModel
    let density: OpenRouterRowDensity
    let showsRetiring: Bool
    let isCompact: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.name)
                    .font(.system(size: isCompact ? 11 : 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let created = model.created {
                    Text(Formatting.shortAge(since: created, now: now))
                        .font(.system(size: isCompact ? 9.5 : 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if density != .lean {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.shortID)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(OpenRouterFormat.prices(of: model))
                        .monospacedDigit()
                        .layoutPriority(1)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            if density == .detail {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(details)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    badges
                }
                .padding(.top, 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// `1M ctx · text·image·file → text`
    private var details: String {
        [model.contextLength.map { "\(OpenRouterFormat.context($0)) ctx" }, OpenRouterFormat.modalities(of: model)]
            .compactMap(\.self).joined(separator: " · ")
    }

    @ViewBuilder
    private var badges: some View {
        if model.isFreeVariant { OpenRouterBadge(title: "Free", color: .green) }
        if showsRetiring, model.isRetiring(asOf: now), let day = model.expiration {
            OpenRouterBadge(title: "Retiring \(OpenRouterFormat.day(day))", color: .orange)
        }
        if model.inputPrice == .varies || model.outputPrice == .varies {
            OpenRouterBadge(title: "Varies", color: .secondary)
        }
    }

    private var accessibilityLabel: String {
        var parts = [model.name]
        if let created = model.created {
            parts.append("added \(created.formatted(.relative(presentation: .named)))")
        }
        if density != .lean {
            parts.append(
                "\(OpenRouterFormat.pricePerMillion(model.inputPrice)) input, "
                    + "\(OpenRouterFormat.pricePerMillion(model.outputPrice)) output per million tokens")
        }
        if density == .detail { parts.append(details) }
        return parts.joined(separator: ", ")
    }
}

/// Right-click on a model: open it, or copy its ID.
struct OpenRouterModelMenu: View {
    let model: OpenRouterModel

    var body: some View {
        if let url = model.pageURL {
            Button("Open on openrouter.ai", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
        }
        Button("Copy Model ID", systemImage: "doc.on.doc") { SessionHost.copy(model.id) }
    }
}

// MARK: - Previews

extension OpenRouterCatalogue {
    /// What previews show until the catalogue is fetched: a few entries as OpenRouter listed them in October 2026.
    static func sample(at now: Date) -> OpenRouterCatalogue {
        func price(_ perMillion: String) -> OpenRouterTokenPrice {
            .perToken(Decimal(string: perMillion)! / 1_000_000)
        }
        let day: TimeInterval = 24 * 60 * 60
        let models = [
            OpenRouterModel(
                id: "meta/muse-wonder", name: "Meta: Muse Wonder", created: now.addingTimeInterval(-0.4 * day),
                contextLength: 1_048_576, inputModalities: ["text", "image", "file", "audio", "video"],
                outputModalities: ["text"], inputPrice: price("4"), outputPrice: price("20")),
            OpenRouterModel(
                id: "stepfun/step-5-preview", name: "StepFun: Step 5 Preview",
                created: now.addingTimeInterval(-4.2 * day), contextLength: 1_000_000,
                inputModalities: ["text", "image", "video"], outputModalities: ["text"], inputPrice: price("1"),
                outputPrice: price("2.70")),
            OpenRouterModel(
                id: "anthropic/claude-haiku-5.5", name: "Anthropic: Claude Haiku 5.5",
                created: now.addingTimeInterval(-5.6 * day), contextLength: 1_000_000,
                inputModalities: ["text", "image", "file"], outputModalities: ["text"], inputPrice: price("0.10"),
                outputPrice: price("0.50")),
            OpenRouterModel(
                id: "apodex/apodex-1.1-mini:free", name: "Apodex: Apodex 1.1 Mini (free)",
                created: now.addingTimeInterval(-11.3 * day), contextLength: 262_144, inputModalities: ["text"],
                outputModalities: ["text"], inputPrice: price("0"), outputPrice: price("0"),
                expiration: UTCDay(now.addingTimeInterval(18 * day))),
            OpenRouterModel(
                id: "openrouter/auto", name: "Auto Router", created: now.addingTimeInterval(-300 * day),
                contextLength: 2_000_000, inputModalities: ["text", "image"], outputModalities: ["text"],
                inputPrice: .varies, outputPrice: .varies),
            OpenRouterModel(
                id: "openai/gpt-4.1", name: "OpenAI: GPT-4.1", created: now.addingTimeInterval(-547 * day),
                contextLength: 1_047_576, inputModalities: ["text", "image", "file"], outputModalities: ["text"],
                inputPrice: price("2"), outputPrice: price("8")),
        ]
        return OpenRouterCatalogue(models: models, fetchedAt: now.addingTimeInterval(-12 * 60))
    }
}
