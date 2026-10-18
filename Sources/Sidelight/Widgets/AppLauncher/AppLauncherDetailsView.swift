import AppKit
import Carbon.HIToolbox
import Observation
import SidelightCore
import SwiftUI

/// Which apps the details panel lists.
enum LauncherScope: Hashable, CaseIterable {
    /// The launcher's own, in its order.
    case pinned
    /// Dock apps running now.
    case running
    /// Every app installed in the usual places, and any other running.
    case all
}

/// What someone is doing in the launcher's details panel: their search, the scope, the selected app, and every app
/// installed, read once when it opens. Forgotten when the panel closes, icons and all.
@Observable
final class AppLauncherBrowser {
    let widgetID: WidgetInstance.ID
    var search = ""
    var scope: LauncherScope
    var selection: LauncherItem.ID?
    /// Every installed app; `nil` while they're still being looked for.
    private(set) var catalog: [CatalogApp]?
    /// The rows listed now, in order, for the arrow keys and Return.
    @ObservationIgnored var listed: [LauncherItem] = []
    /// How rows open, set by the view.
    @ObservationIgnored var actions: LauncherItemActions?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// Every listed app's icon, kept only while the panel is open.
    @ObservationIgnored private var icons: [String: NSImage] = [:]

    init(widgetID: WidgetInstance.ID, scope: LauncherScope) {
        self.widgetID = widgetID
        self.scope = scope
    }

    deinit {
        scanTask?.cancel()
    }

    /// Looks for every installed app, once, off the main actor.
    func scanIfNeeded(running: @escaping () -> [RunningAppInfo]) {
        guard scanTask == nil else { return }
        let roots = AppCatalog.defaultRoots(home: URL.homeDirectory)
        scanTask = Task { [weak self] in
            let scanned = await AppCatalog.scan(roots)
            guard !Task.isCancelled, let self else { return }
            catalog = AppCatalog.merging(scanned, running: running())
        }
    }

    func icon(atPath path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    /// Handles the arrow keys and Return before the search field does: ↑↓ choose an app, ↩ opens it (or the first)
    /// and closes the panel, ⌘↩ shows it in Finder. Typing goes to the search, which has focus; Esc closes as usual.
    func handlesKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let keyCode = Int(event.keyCode)
        let isReturn = keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter
        switch (keyCode, flags) {
        case (kVK_DownArrow, []): return moveSelection(by: 1)
        case (kVK_UpArrow, []): return moveSelection(by: -1)
        default: break
        }
        guard isReturn, let item = listed.first(where: { $0.id == selection }) ?? listed.first,
            let actions
        else { return false }
        if flags == .command, let url = item.url {
            AppLauncherActions.reveal(url)
            return true
        }
        guard flags.isEmpty else { return false }
        actions.open(item)
        return true
    }

    private func moveSelection(by offset: Int) -> Bool {
        let ids = listed.map(\.id)
        guard !ids.isEmpty else { return true }
        guard let selection, let index = ids.firstIndex(of: selection) else {
            self.selection = offset >= 0 ? ids.first : ids.last
            return true
        }
        self.selection = ids[min(max(index + offset, 0), ids.count - 1)]
        return true
    }
}

/// Every app, in the details panel: the launcher's own, those running, or all installed, searchable and driven from
/// the keyboard, with pinning and the same menu as the widget.
struct AppLauncherDetailsView: View {
    let browser: AppLauncherBrowser
    @Environment(AppLauncherService.self) private var service
    @Environment(ConfigurationStore.self) private var store
    @Environment(AccessibilityPermission.self) private var accessibility
    @Environment(\.closeDetails) private var closeDetails
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let settings = self.settings
        let items = self.items(settings: settings)
        // Every time, not only when the rows change: a located app keeps its row but moves.
        browser.listed = items
        browser.actions = actions(settings: settings)
        return VStack(alignment: .leading, spacing: 0) {
            controls(settings: settings)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            HairlineDivider()
            list(items, settings: settings)
        }
        .defaultFocus($isSearchFocused, true)
        .onAppear {
            isSearchFocused = true
            browser.scanIfNeeded { [service] in service.running.apps }
        }
        .onChange(of: items.map(\.id), initial: true) {
            if let selection = browser.selection, !items.contains(where: { $0.id == selection }) {
                browser.selection = nil
            }
        }
    }

    /// The launcher's settings; `nil` once it's removed, and nothing can be pinned.
    private var settings: AppLauncherSettings? {
        guard case .appLauncher(let settings) = store.configuration.widget(browser.widgetID)?.settings else {
            return nil
        }
        return settings
    }

    private func actions(settings: AppLauncherSettings?) -> LauncherItemActions {
        let id = browser.widgetID
        return LauncherItemActions(
            service: service,
            edit: { [store] change in
                guard settings != nil else { return }
                store.configuration.updateAppLauncher(id, change)
            },
            showAllApps: nil, canPressMenus: accessibility.isTrusted,
            didOpen: { [closeDetails] in closeDetails?() })
    }

    // MARK: Rows

    private func items(settings: AppLauncherSettings?) -> [LauncherItem] {
        let pinned = settings?.apps ?? []
        let search = AppSearch(browser.search)
        let items: [LauncherItem]
        switch browser.scope {
        case .pinned:
            items = pinned.map { LauncherItem(pinned: $0, service: service) }
        case .running:
            // A pinned app running more than once is one row, with every copy.
            var listedPinned: Set<LauncherApp.ID> = []
            items = service.running.apps.filter(\.isRegular).filter { $0.bundleID != Bundle.main.bundleIdentifier }
                .compactMap { info in
                    if let app = pinned.first(where: { service.instances(of: $0).contains(info) }) {
                        guard listedPinned.insert(app.id).inserted else { return nil }
                        return LauncherItem(pinned: app, service: service)
                    }
                    return LauncherItem(running: info)
                }
        case .all:
            let byPath = Dictionary(
                pinned.compactMap { app in
                    service.resolve(app).url.map { (LauncherApp.standardize($0.path(percentEncoded: false)), app) }
                }, uniquingKeysWith: { first, _ in first })
            items = (browser.catalog ?? []).map { app in
                LauncherItem(
                    catalog: app, pinned: byPath[app.path],
                    instances: service.running.apps.filter { $0.path == app.path })
            }
        }
        return ranked(items, by: search)
    }

    private func ranked(_ items: [LauncherItem], by search: AppSearch) -> [LauncherItem] {
        guard !search.isEmpty else { return items }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let apps = items.map { item in
            CatalogApp(path: item.id, bundleID: item.bundleID, name: item.name, folder: .elsewhere)
        }
        return search.ranked(apps).compactMap { byID[$0.path] }
    }

    // MARK: Controls

    private func controls(settings: AppLauncherSettings?) -> some View {
        @Bindable var browser = browser
        let runningCount = service.running.apps.count { $0.isRegular && $0.bundleID != Bundle.main.bundleIdentifier }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search apps", text: $browser.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($isSearchFocused)
                    .accessibilityLabel("Search apps")
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

            Picker("Show", selection: $browser.scope.animation(Motion.snappy)) {
                Text("In Launcher \(settings?.apps.count ?? 0)").tag(LauncherScope.pinned)
                Text("Running \(runningCount)").tag(LauncherScope.running)
                Text(browser.catalog.map { "All \($0.count)" } ?? "All").tag(LauncherScope.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
        }
    }

    // MARK: List

    @ViewBuilder
    private func list(_ items: [LauncherItem], settings: AppLauncherSettings?) -> some View {
        if browser.scope == .all, browser.catalog == nil {
            emptyState("Looking for apps…", detail: nil)
        } else if items.isEmpty {
            emptyState(settings: settings)
        } else if browser.scope == .pinned, browser.search.isEmpty, settings != nil {
            // The one place besides settings to reorder the launcher, by dragging.
            ScrollViewReader { proxy in
                List {
                    ForEach(items) { item in
                        row(item, items: items, canPin: true)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                    }
                    .onMove { source, destination in
                        store.configuration.updateAppLauncher(browser.widgetID) {
                            $0.move(fromOffsets: source, toOffset: destination)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: browser.selection) { _, id in scroll(to: id, with: proxy) }
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { item in
                            row(item, items: items, canPin: settings != nil)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.automatic)
                .onChange(of: browser.selection) { _, id in scroll(to: id, with: proxy) }
            }
        }
    }

    /// Keeps the app chosen with the arrow keys in view.
    private func scroll(to id: LauncherItem.ID?, with proxy: ScrollViewProxy) {
        guard let id else { return }
        withAnimation(Motion.snappy) { proxy.scrollTo(id) }
    }

    private func row(_ item: LauncherItem, items: [LauncherItem], canPin: Bool) -> some View {
        let actions = actions(settings: settings)
        let isSelected = browser.selection == item.id
        let sharesName = items.count { $0.name == item.name } > 1
        return HStack(spacing: 8) {
            Image(nsImage: browser.icon(atPath: item.iconPath))
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
                .opacity(item.isMissing ? 0.35 : 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                if item.isMissing {
                    Text("Not found").font(.system(size: 10.5)).foregroundStyle(.orange)
                } else if sharesName, let url = item.url {
                    Text(url.path(percentEncoded: false))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if item.isRunning {
                Circle().fill(.primary.opacity(0.55)).frame(width: 5, height: 5)
                    .accessibilityHidden(true)
            }
            if canPin {
                Button {
                    if item.pinned != nil { actions.unpin(item) } else { actions.pin(item) }
                } label: {
                    Image(systemName: item.pinned != nil ? "checkmark.circle.fill" : "plus.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(item.pinned != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .disabled(item.pinned == nil && item.launcherApp == nil)
                .help(item.pinned != nil ? "Remove from the launcher" : "Keep in the launcher")
                .accessibilityLabel(item.pinned != nil ? "Remove from the launcher" : "Keep in the launcher")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.1 : 0))
        )
        .contentShape(.rect)
        .onTapGesture {
            browser.selection = item.id
            actions.click(item)
        }
        .hoverHighlight(opacity: isSelected ? 0 : 0.06, vertical: 0)
        .contextMenu { LauncherAppMenu(item: item, actions: actions) }
        .help(item.url?.path(percentEncoded: false) ?? item.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.isRunning ? "\(item.name), running" : item.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { actions.open(item) }
    }

    @ViewBuilder
    private func emptyState(settings: AppLauncherSettings?) -> some View {
        if !browser.search.isEmpty {
            emptyState("No apps match “\(browser.search)”", detail: nil)
        } else {
            switch browser.scope {
            case .running: emptyState("Nothing running", detail: nil)
            case .all: emptyState("No apps found", detail: nil)
            case .pinned:
                VStack(alignment: .leading, spacing: 8) {
                    emptyState(
                        "No apps in this launcher",
                        detail: settings == nil ? nil : "Add some from all your apps, or drop them on the widget.")
                    if settings != nil {
                        Button("Show All") { withAnimation(Motion.snappy) { browser.scope = .all } }
                            .controlSize(.small)
                            .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    private func emptyState(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12.5, weight: .medium))
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
