import Observation
import SidelightCore
import SwiftUI

/// The details panel's tabs for a Runware account.
enum RunwareDetailsTab: String, CaseIterable, Identifiable, Hashable {
    case usage
    case history
    case models

    var id: Self { self }

    var title: String {
        switch self {
        case .usage: "Usage"
        case .history: "History"
        case .models: "Models"
        }
    }
}

/// What someone is doing in a Runware account's details panel: the tab, the day opened, the model search and its
/// pages. Forgotten when the panel closes; it never changes the widget's settings.
@Observable
final class RunwareBrowser {
    /// The account shown. Switching it changes what the panel needs fetched.
    var account: AccountID
    var tab: RunwareDetailsTab
    var chartMetric = RunwareChartMetric.spend
    /// The History tab's day shown with its models.
    var expandedDay: UTCDay?
    /// The Models tab's search and filters.
    var query = RunwareModelQuery()
    /// The Models tab's model shown in detail.
    var expandedModel: RunwareModel.ID?
    /// The pages of the current search loaded so far.
    private(set) var pages: [RunwareModelPage] = []
    private(set) var searchProblem: RunwareProblem?
    private(set) var isSearching = false
    /// Runware turned down a search for nothing: the catalogue lists only once something is typed.
    private(set) var needsSearchText = false

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private let debounce = DelayedTask()

    init(account: AccountID, tab: RunwareDetailsTab) {
        self.account = account
        self.tab = tab
    }

    /// Every model loaded, each once, in the order Runware listed them.
    var models: [RunwareModel] {
        var seen = Set<String>()
        return pages.flatMap(\.models).filter { seen.insert($0.air).inserted }
    }

    var total: Int? { pages.last?.total }

    var canLoadMore: Bool { !isSearching && pages.last?.nextOffset != nil }

    /// Searches again from the first page: after `delay` while typing, right away for a filter.
    func search(in account: RunwareAccount, after delay: Duration = .zero) {
        debounce.cancel()
        searchTask?.cancel()
        guard delay > .zero else {
            start(query.firstPage, in: account, appending: false)
            return
        }
        debounce.schedule(after: delay) { [weak self] in
            guard let self else { return }
            start(query.firstPage, in: account, appending: false)
        }
    }

    /// The next page of the current search: one request per click.
    func loadMore(in account: RunwareAccount) {
        guard canLoadMore, let next = pages.last?.nextOffset else { return }
        var query = query.firstPage
        query.offset = next
        start(query, in: account, appending: true)
    }

    /// Another account: what the last one found (its private models too) goes.
    func accountChanged() {
        stop()
        pages = []
        searchProblem = nil
        needsSearchText = false
        expandedDay = nil
        expandedModel = nil
    }

    /// Stops searching: the panel closed.
    func stop() {
        debounce.cancel()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    private func start(_ query: RunwareModelQuery, in account: RunwareAccount, appending: Bool) {
        searchTask?.cancel()
        if !appending, !query.hasSearch, needsSearchText {
            pages = []
            searchProblem = nil
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            let result = await account.searchModels(query)
            guard let self, !Task.isCancelled else { return }
            isSearching = false
            switch result {
            case .success(let page):
                pages = appending ? pages + [page] : [page]
                searchProblem = nil
            case .failure(.badRequest) where !query.hasSearch:
                // Runware wants something to search for.
                needsSearchText = true
                pages = []
                searchProblem = nil
            case .failure(let problem):
                if !appending { pages = [] }
                searchProblem = problem
            case nil:
                break
            }
        }
    }
}

/// A Runware account in the details panel: usage, a day-by-day history, and the model catalogue.
struct RunwareDetailsView: View {
    let browser: RunwareBrowser
    @Environment(RunwareService.self) private var service
    @Environment(AccountStore.self) private var accounts

    var body: some View {
        @Bindable var browser = browser
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Picker("Tab", selection: $browser.tab.animation(Motion.snappy)) {
                        ForEach(RunwareDetailsTab.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    accountMenu
                }
                if let account = service.account(browser.account) {
                    WidgetClock { now in RunwareDetailsStatus(account: account, now: now) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            HairlineDivider()
            if let account = service.account(browser.account) {
                WidgetClock { now in
                    switch browser.tab {
                    case .usage: RunwareUsageTab(account: account, browser: browser, now: now)
                    case .history: RunwareHistoryTab(account: account, browser: browser, now: now)
                    case .models: RunwareModelsTab(account: account, browser: browser)
                    }
                }
                .id(browser.account)
                .onAppear { account.refreshActivityIfStale() }
                .onDisappear {
                    browser.stop()
                    account.cancelDayModelLoads()
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Another account, or another key for this one (perhaps another organization): what was found goes.
        .onChange(of: shownKey) { old, new in
            browser.accountChanged()
            // Another account's tab is made anew and searches on appearing; this one searches again itself.
            if old.account == new.account, old.generation != nil, browser.tab == .models,
                let account = service.account(new.account)
            {
                browser.search(in: account)
            }
        }
    }

    /// The account shown and which of its keys.
    private struct ShownKey: Equatable {
        let account: AccountID
        let generation: Int?
    }

    private var shownKey: ShownKey {
        ShownKey(account: browser.account, generation: service.account(browser.account)?.keyGeneration)
    }

    /// Another Runware account, when there's more than one to choose from.
    @ViewBuilder
    private var accountMenu: some View {
        @Bindable var browser = browser
        let choices = accounts.choices(at: .runware, using: browser.account)
        if choices.count > 1 {
            Picker("Account", selection: $browser.account) {
                ForEach(choices) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// The organization, and how fresh what's shown is: `Acme Corporation · Updated 2m ago ⟳`.
private struct RunwareDetailsStatus: View {
    let account: RunwareAccount
    let now: Date

    var body: some View {
        let details = account.details
        HStack(spacing: 2) {
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(details.problem == nil ? Color.secondary : .orange)
                .lineLimit(1)
            if details.problem?.needsKey != true {
                OpenRouterRefreshButton(
                    isFetching: details.isFetching || account.activity.isFetching, help: "Fetch from Runware now"
                ) { account.refresh(includingActivity: true) }
            }
        }
        .help(details.problem.map { "\($0.title). \($0.advice)" } ?? "")
    }

    private var text: String {
        let details = account.details
        guard let value = details.value else {
            return details.problem?.title ?? "Connecting to Runware…"
        }
        let age = UsageFormat.age(of: value.fetchedAt, now: now)
        let name = value.organizationName ?? "Runware"
        guard let problem = details.problem else { return "\(name) · Updated \(age)" }
        return "\(name) · \(problem.title) · \(age)"
    }
}

/// A section's heading.
private struct RunwareSectionTitle: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Usage

private struct RunwareUsageTab: View {
    let account: RunwareAccount
    @Bindable var browser: RunwareBrowser
    let now: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let details = account.details.value {
                    balance(details)
                    totals(details)
                } else if let problem = account.details.problem {
                    RunwareNote(
                        text: "\(problem.title). \(problem.advice)", systemImage: "exclamationmark.triangle",
                        isCompact: false)
                }
                chart
                models
                if let details = account.details.value, !details.apiKeys.isEmpty { keys(details) }
                Text("Requests, not images: one request can return several results, or none.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
        }
    }

    private var currency: String { account.details.value?.balance.currency ?? "USD" }

    private func balance(_ details: RunwareAccountDetails) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            RunwareSectionTitle(title: "Balance · \(details.balance.currency)")
            Text(RunwareFormat.money(details.balance.amount, currency: details.balance.currency))
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(details.balance.amount < 0 ? Color.red : .primary)
                .accessibilityLabel(details.balance.accessibilityText)
            if let free = details.balance.freeBalance, free > 0 {
                Text("+ \(RunwareFormat.money(free, currency: details.balance.currency)) free credits")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func totals(_ details: RunwareAccountDetails) -> some View {
        let rows: [(String, RunwareUsageTotal?)] = [
            ("Today", details.usage.today), ("7 days", details.usage.last7Days),
            ("30 days", details.usage.last30Days), ("All time", details.usage.total),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            RunwareSectionTitle(title: "Usage")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(rows, id: \.0) { title, total in
                    GridRow {
                        Text(title).foregroundStyle(.secondary)
                        Text(total?.spend.map { RunwareFormat.money($0, currency: details.balance.currency) } ?? "—")
                            .gridColumnAlignment(.trailing)
                        Text(total?.requests.map(RunwareFormat.requests) ?? "—")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                }
            }
            .help("Runware's totals. Sidelight's own reads may count as requests too.")
        }
    }

    @ViewBuilder
    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                RunwareSectionTitle(title: "Last 30 days · UTC")
                Spacer()
                Picker("Shows", selection: $browser.chartMetric) {
                    ForEach(RunwareChartMetric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            if let activity = account.activity.value {
                RunwareBars(
                    days: activity.days, metric: browser.chartMetric, currency: currency,
                    partialDay: activity.window.upperBound, height: 44)
                Text(caption(activity))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                activityNote
            }
        }
    }

    private func caption(_ activity: RunwareActivity) -> String {
        let spend = activity.totalSpend ?? RunwareActivity.spend(of: activity.days)
        let requests = activity.totalRequests ?? RunwareActivity.requests(of: activity.days)
        return "\(RunwareFormat.money(spend, currency: currency)) · \(RunwareFormat.requests(requests)) · "
            + "updated \(UsageFormat.age(of: activity.fetchedAt, now: now))"
    }

    @ViewBuilder
    private var activityNote: some View {
        if let problem = account.activity.problem {
            RunwareNote(text: "\(problem.title). \(problem.advice)", systemImage: "chart.bar.xaxis", isCompact: false)
        } else {
            RunwareNote(text: "Loading activity…", systemImage: "hourglass", isCompact: false)
        }
    }

    @ViewBuilder
    private var models: some View {
        if let activity = account.activity.value {
            let top = activity.models.compactMap { $0.spend?.approximateDouble }.max() ?? 0
            VStack(alignment: .leading, spacing: 8) {
                RunwareSectionTitle(title: "Models used · 30 days")
                if activity.models.isEmpty {
                    Text("No models used").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(activity.models) { model in
                    RunwareModelUsageRow(
                        model: model, currency: currency,
                        share: top > 0 ? (model.spend?.approximateDouble ?? 0) / top : 0, isCompact: false,
                        showsAIR: true, showsRequests: true)
                }
            }
        }
    }

    private func keys(_ details: RunwareAccountDetails) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RunwareSectionTitle(title: "API keys")
            ForEach(Array(details.keysByLastUse.enumerated()), id: \.offset) { _, key in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(key.isEnabled ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(key.name).font(.system(size: 11.5)).lineLimit(1)
                    if !key.isEnabled {
                        Text("Disabled").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(lastUse(key))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// `1,250 requests · last used 3h ago`
    private func lastUse(_ key: RunwareAPIKeySummary) -> String {
        [
            key.requests.map(RunwareFormat.requests),
            key.lastUsedAt.map { "last used \(UsageFormat.age(of: $0, now: now))" } ?? "never used",
        ].compactMap(\.self).joined(separator: " · ")
    }
}

// MARK: - History

private struct RunwareHistoryTab: View {
    let account: RunwareAccount
    @Bindable var browser: RunwareBrowser
    let now: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                RunwareSectionTitle(title: "Last 30 days · UTC")
                    .padding(.bottom, 6)
                if let activity = account.activity.value {
                    ForEach(activity.days.reversed()) { day in
                        row(day, in: activity)
                    }
                } else if let problem = account.activity.problem {
                    RunwareNote(text: "\(problem.title). \(problem.advice)", systemImage: "calendar", isCompact: false)
                } else {
                    RunwareNote(text: "Loading activity…", systemImage: "hourglass", isCompact: false)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "Runware doesn't offer a list of individual generations to apps. See each one in the Runware "
                            + "dashboard.")
                    Link("Open the Runware dashboard", destination: RunwareFormat.dashboard)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            }
            .padding(14)
        }
    }

    private var currency: String { account.details.value?.balance.currency ?? "USD" }

    @ViewBuilder
    private func row(_ day: RunwareDay, in activity: RunwareActivity) -> some View {
        let isExpanded = browser.expandedDay == day.day
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(Motion.snappy) {
                    browser.expandedDay = isExpanded ? nil : day.day
                }
                if !isExpanded { account.loadDayModels(day.day) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(activity.isPartial(day.day) ? "Today (so far)" : RunwareFormat.day(day.day))
                        .font(.system(size: 11.5, weight: activity.isPartial(day.day) ? .semibold : .regular))
                    Spacer(minLength: 4)
                    if day.isReported {
                        Text(day.requests.map(RunwareFormat.requests) ?? "—")
                            .foregroundStyle(.secondary)
                        Text(day.spend.map { RunwareFormat.amount($0, currency: currency) } ?? "—")
                            .frame(minWidth: 64, alignment: .trailing)
                    } else {
                        Text("Nothing reported").foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .hoverHighlight(vertical: 2)
            .disabled(!day.isReported)
            if isExpanded { dayModels(day.day) }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func dayModels(_ day: UTCDay) -> some View {
        Group {
            switch account.activityDayModels(day).map(RunwareAccount.DayModelsState.loaded) ?? account.dayModels[day] {
            case .loading, nil:
                ProgressView().controlSize(.small)
            case .failed(let problem):
                HStack(spacing: 6) {
                    Text("Couldn't load this day").foregroundStyle(.secondary)
                    Button("Try Again") { account.loadDayModels(day) }
                        .controlSize(.mini)
                }
                .font(.system(size: 10.5))
                .help("\(problem.title). \(problem.advice)")
            case .loaded(let loaded):
                if loaded.models.isEmpty {
                    Text("No models reported").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                let top = loaded.models.compactMap { $0.spend?.approximateDouble }.max() ?? 0
                ForEach(loaded.models) { model in
                    RunwareModelUsageRow(
                        model: model, currency: currency,
                        share: top > 0 ? (model.spend?.approximateDouble ?? 0) / top : 0, isCompact: false,
                        showsRequests: true)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.bottom, 4)
    }
}

// MARK: - Models

private struct RunwareModelsTab: View {
    let account: RunwareAccount
    @Bindable var browser: RunwareBrowser
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            HairlineDivider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !browser.query.hasSearch, let activity = account.activity.value, !activity.models.isEmpty {
                        RunwareSectionTitle(title: "Used recently")
                        ForEach(activity.models.prefix(8)) { model in
                            usedRow(model)
                        }
                        if !browser.models.isEmpty {
                            RunwareSectionTitle(title: "Catalogue").padding(.top, 6)
                        }
                    }
                    results
                }
                .padding(14)
            }
        }
        .defaultFocus($isSearchFocused, true)
        .onAppear {
            isSearchFocused = true
            if browser.pages.isEmpty, !browser.isSearching { browser.search(in: account) }
        }
        .onChange(of: browser.query.search) { browser.search(in: account, after: .milliseconds(300)) }
        .onChange(of: browser.query.category) { browser.search(in: account) }
        .onChange(of: browser.query.source) { browser.search(in: account) }
        .onChange(of: browser.query.visibility) { browser.search(in: account) }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search by name or AIR", text: $browser.query.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($isSearchFocused)
                    .accessibilityLabel("Search models")
                if browser.isSearching { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
            HStack(spacing: 8) {
                filter("Category", RunwareModelQuery.categories, selection: $browser.query.category)
                filter("Source", RunwareModelQuery.sources, selection: $browser.query.source)
                filter("Visibility", RunwareModelQuery.visibilities, selection: $browser.query.visibility)
                Spacer(minLength: 0)
            }
        }
    }

    private func filter(_ title: String, _ values: [String], selection: Binding<String?>) -> some View {
        Menu {
            Picker(title, selection: selection) {
                Text("Any").tag(String?.none)
                ForEach(values, id: \.self) { Text(Self.title(of: $0)).tag(Optional($0)) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(selection.wrappedValue.map { Self.title(of: $0) } ?? title)
                .font(.system(size: 11))
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }

    /// `LoRA`, `Mine` for `owned`, `Favorites`; others capitalized.
    private static func title(of value: String) -> String {
        switch value {
        case "owned": "Mine"
        case "favorite": "Favorites"
        case "lora": "LoRA"
        case "vae": "VAE"
        default: value.prefix(1).uppercased() + value.dropFirst()
        }
    }

    private func usedRow(_ model: RunwareModelUsage) -> some View {
        Button {
            browser.query.search = model.air
        } label: {
            HStack(spacing: 6) {
                Text(model.displayName).font(.system(size: 11.5)).lineLimit(1)
                Spacer(minLength: 4)
                Text(model.air)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight(vertical: 2)
        .contextMenu {
            Button("Copy AIR", systemImage: "doc.on.doc") { SessionHost.copy(model.air) }
        }
        .help("Find \(model.air) in the catalogue")
    }

    @ViewBuilder
    private var results: some View {
        if let problem = browser.searchProblem {
            VStack(alignment: .leading, spacing: 6) {
                RunwareNote(
                    text: "\(problem.title). \(problem.advice)", systemImage: "exclamationmark.triangle",
                    isCompact: false)
                if !problem.needsKey {
                    Button("Try Again") { browser.search(in: account) }.controlSize(.small)
                }
            }
        } else if browser.needsSearchText, !browser.query.hasSearch {
            Text("Type to search Runware's models.").font(.system(size: 11)).foregroundStyle(.secondary)
        } else if browser.models.isEmpty, !browser.isSearching, !browser.pages.isEmpty {
            Text("No models match.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        ForEach(browser.models) { model in
            RunwareCatalogueRow(
                model: model, isExpanded: browser.expandedModel == model.id,
                toggle: {
                    withAnimation(Motion.snappy) {
                        browser.expandedModel = browser.expandedModel == model.id ? nil : model.id
                    }
                })
        }
        if browser.canLoadMore {
            Button(loadMoreTitle) { browser.loadMore(in: account) }
                .controlSize(.small)
                .padding(.top, 4)
        }
    }

    /// `Load more (50 of 1,284)`
    private var loadMoreTitle: String {
        guard let total = browser.total else { return "Load more" }
        return "Load more (\(browser.models.count.formatted()) of \(total.formatted()))"
    }
}

/// A catalogue model: its name and version, then `architecture · category` and its AIR; opened, its tags, defaults
/// and ways to copy it.
private struct RunwareCatalogueRow: View {
    let model: RunwareModel
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(model.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if let version = model.version {
                            Text(version).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if model.isPrivate { OpenRouterBadge(title: "Private", color: .secondary) }
                        Spacer(minLength: 4)
                    }
                    HStack(spacing: 6) {
                        let kind = [model.architecture, model.category].compactMap(\.self).joined(separator: " · ")
                        if !kind.isEmpty { Text(kind) }
                        Spacer(minLength: 4)
                        Text(model.air)
                            .font(.system(size: 9.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .hoverHighlight(vertical: 3)
            .contextMenu {
                Button("Copy AIR", systemImage: "doc.on.doc") { SessionHost.copy(model.air) }
                Button("Copy as JSON", systemImage: "curlybraces") { SessionHost.copy(model.requestJSON) }
            }
            if isExpanded { expanded }
        }
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !model.tags.isEmpty {
                Text(model.tags.prefix(12).joined(separator: ", "))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let defaults = defaultsText
            if !defaults.isEmpty {
                Text(defaults).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Copy AIR") { SessionHost.copy(model.air) }
                Button("Copy as JSON") { SessionHost.copy(model.requestJSON) }
            }
            .controlSize(.small)
        }
        .padding(.leading, 8)
        .padding(.bottom, 4)
    }

    /// `Base · 1024×1024 · 20 steps · CFG 7.5`
    private var defaultsText: String {
        var parts: [String] = []
        if let type = model.type { parts.append(type.prefix(1).uppercased() + type.dropFirst()) }
        if let width = model.defaultWidth, let height = model.defaultHeight { parts.append("\(width)×\(height)") }
        if let steps = model.defaultSteps { parts.append("\(steps) steps") }
        if let cfg = model.defaultCFG {
            parts.append("CFG \(cfg.formatted(.number.precision(.fractionLength(0...1))))")
        }
        return parts.joined(separator: " · ")
    }
}
