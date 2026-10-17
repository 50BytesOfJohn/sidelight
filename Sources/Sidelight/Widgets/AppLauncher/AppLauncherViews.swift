import AppKit
import SidelightCore
import SwiftUI
import UniformTypeIdentifiers

/// One app a launcher or the details panel shows: a pinned one, or one that's only running.
struct LauncherItem: Identifiable {
    let id: String
    let name: String
    /// Where it is now; `nil` when it can't be found.
    let url: URL?
    let bundleID: String?
    /// The pinned app, if it's pinned.
    let pinned: LauncherApp?
    let instances: [RunningAppInfo]

    var isRunning: Bool { !instances.isEmpty }
    var isMissing: Bool { url == nil }
    var iconPath: String { url?.path(percentEncoded: false) ?? pinned?.path ?? "" }

    /// What it's pinned as, or would be.
    var launcherApp: LauncherApp? {
        if let pinned { return pinned }
        guard let url else { return nil }
        return LauncherApp(
            path: LauncherApp.standardize(url.path(percentEncoded: false)), bundleID: bundleID, name: name)
    }

    init(pinned app: LauncherApp, service: AppLauncherService) {
        id = app.id.uuidString
        name = app.name
        url = service.resolve(app).url
        bundleID = app.bundleID
        pinned = app
        instances = service.instances(of: app)
    }

    init(running info: RunningAppInfo) {
        id = "pid-\(info.id)"
        name = info.name
        url = info.path.map { URL(filePath: $0, directoryHint: .isDirectory) }
        bundleID = info.bundleID
        pinned = nil
        instances = [info]
    }

    init(catalog app: CatalogApp, pinned: LauncherApp?, instances: [RunningAppInfo]) {
        id = app.path
        name = app.name
        url = URL(filePath: app.path, directoryHint: .isDirectory)
        bundleID = app.bundleID
        self.pinned = pinned
        self.instances = instances
    }
}

/// What a launcher can do to one of its apps: open it, and everything its menu offers. Previews have none.
struct LauncherItemActions {
    let service: AppLauncherService
    /// Changes the launcher's pinned apps; `nil` where nothing may be changed.
    var edit: ((inout AppLauncherSettings) -> Void) -> Void
    /// Opens the details panel; `nil` outside a real panel.
    var showAllApps: (() -> Void)?
    /// Whether New Window can work: Sidelight has Accessibility access.
    var canPressMenus: Bool
    /// Runs after an app was opened, such as to close the details panel.
    var didOpen: () -> Void = {}

    /// A click opens it; ⌘-click shows it in Finder.
    func click(_ item: LauncherItem) {
        guard let url = item.url else {
            NSSound.beep()
            return
        }
        if NSEvent.modifierFlags.contains(.command) {
            AppLauncherActions.reveal(url)
            return
        }
        open(item)
    }

    func open(_ item: LauncherItem) {
        guard let url = item.url else { return }
        AppLauncherActions.open(url, id: item.pinned?.id, service: service)
        didOpen()
    }

    func newWindow(_ item: LauncherItem) {
        guard let url = item.url else { return }
        Task { await AppLauncherActions.newWindow(item.instances, url: url, id: item.pinned?.id, service: service) }
        didOpen()
    }

    func pin(_ item: LauncherItem, at index: Int? = nil) {
        guard let app = item.launcherApp else { return }
        edit { $0.add([app], at: index) }
    }

    func unpin(_ item: LauncherItem) {
        guard let id = item.pinned?.id else { return }
        edit { $0.remove(id) }
    }

    /// Asks where a missing app went, and points the pinned app there, keeping its place.
    func locate(_ item: LauncherItem) {
        guard let pinned = item.pinned else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "Choose"
        panel.message = "Where is \(pinned.name)?"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let app = AppCatalog.app(at: url)
        edit { settings in
            guard let index = settings.apps.firstIndex(where: { $0.id == pinned.id }) else { return }
            settings.apps[index] = LauncherApp(id: pinned.id, path: app.path, bundleID: app.bundleID, name: app.name)
        }
    }
}

// MARK: - Icon

/// One app's icon, with a dot under it while it runs, and its name in the regular layout.
struct LauncherIcon: View {
    let item: LauncherItem
    let size: Double
    var showsDot = true
    var label: Bool = false
    var cellWidth: CGFloat?
    var isLaunching = false
    /// `nil` in previews: nothing happens on a click, and there's no menu.
    let actions: LauncherItemActions?
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: AppIcons.icon(atPath: item.iconPath))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .opacity(item.isMissing ? 0.35 : isLaunching ? 0.6 : 1)
                .scaleEffect(isLaunching && !reducesMotion ? 0.88 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if item.isMissing {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: max(size * 0.32, 9)))
                            .foregroundStyle(.secondary)
                    }
                }
                .animation(Motion.snappy, value: isLaunching)
            Circle()
                .fill(.primary.opacity(showsDot && item.isRunning ? 0.55 : 0))
                .frame(width: size <= 28 ? 3 : 4, height: size <= 28 ? 3 : 4)
                .frame(height: LauncherGrid.indicatorHeight)
            if label {
                Text(item.name)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: cellWidth)
            }
        }
        .frame(width: cellWidth)
        .contentShape(.rect)
        .onTapGesture { actions?.click(item) }
        .hoverHighlight(isEnabled: actions != nil, cornerRadius: 6, vertical: 2)
        .contextMenu {
            if let actions { LauncherAppMenu(item: item, actions: actions) }
        }
        .help(item.isMissing ? "\(item.name) can't be found" : item.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { actions?.open(item) }
        .accessibilityActions {
            if let actions { LauncherAppMenu(item: item, actions: actions) }
        }
    }

    private var accessibilityLabel: String {
        if item.isMissing { return "\(item.name), can't be found" }
        return item.isRunning ? "\(item.name), running" : item.name
    }
}

/// The last cell: opens every app in the details panel, or says how many didn't fit.
struct AllAppsTile: View {
    let overflow: Int
    let size: Double
    var cellWidth: CGFloat?
    /// `nil` in previews.
    let open: (() -> Void)?
    var help = "All apps"

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .frame(width: size, height: size)
                .overlay {
                    if overflow > 0 {
                        Text("+\(overflow)")
                            .font(.system(size: max(size * 0.32, 9), weight: .semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    } else {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: size * 0.45, weight: .medium))
                    }
                }
                .foregroundStyle(.secondary)
            Color.clear.frame(height: LauncherGrid.indicatorHeight)
        }
        .frame(width: cellWidth)
        .contentShape(.rect)
        .onTapGesture { open?() }
        .hoverHighlight(isEnabled: open != nil, cornerRadius: 6, vertical: 2)
        .help(open == nil ? "Opens from the panel" : overflow > 0 ? "\(overflow) more apps" : help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(overflow > 0 ? "\(overflow) more apps" : "All apps")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open?() }
    }
}

// MARK: - Menu

/// An app's right-click menu, as the Dock's: built when it opens, from the app's state then.
struct LauncherAppMenu: View {
    let item: LauncherItem
    let actions: LauncherItemActions

    var body: some View {
        let isHidden = item.isRunning && AppLauncherActions.isHidden(item.instances)
        if item.url != nil {
            if !item.isRunning {
                Button("Open") { actions.open(item) }
            } else if !isHidden {
                Button("Show") { actions.open(item) }
            }
            if actions.canPressMenus {
                Button("New Window") { actions.newWindow(item) }
            }
        }
        if item.isRunning {
            Divider()
            if isHidden {
                Button("Show") {
                    AppLauncherActions.unhide(item.instances)
                    actions.open(item)
                }
            } else {
                Button("Hide") { AppLauncherActions.hide(item.instances) }
            }
            Button("Quit") { AppLauncherActions.quit(item.instances) }
            // SwiftUI builds the menu with the view, not when it opens, so it can't hide this behind ⌥: it's set
            // apart and asks first instead.
            Divider()
            Button("Force Quit…") {
                let confirmed = Alert.confirm(
                    title: "Force quit \(item.name)?",
                    message: "Unsaved changes will be lost.",
                    confirmTitle: "Force Quit"
                )
                if confirmed { AppLauncherActions.forceQuit(item.instances) }
            }
        }
        Divider()
        if let url = item.url {
            Button("Show in Finder") { AppLauncherActions.reveal(url) }
        } else if item.pinned != nil {
            Button("Locate…") { actions.locate(item) }
        }
        if item.pinned != nil {
            Button("Remove from Launcher") { actions.unpin(item) }
        } else if item.url != nil {
            Button("Keep in Launcher") { actions.pin(item) }
        }
        if let showAllApps = actions.showAllApps {
            Divider()
            Button("All Apps…", action: showAllApps)
        }
    }
}

// MARK: - Dropping apps

/// Takes apps dragged from Finder onto a launcher, at the gap nearest the pointer. Costs nothing until a drag comes
/// over the window: AppKit only asks while one does.
struct LauncherDropDelegate: DropDelegate {
    /// Previews take no drops: they never change the configuration.
    let isEnabled: Bool
    /// Where drops land in a grid; `nil` adds at the end.
    let grid: LauncherGrid?
    @Binding var insertion: Int?
    @Binding var isTargeted: Bool
    let add: (_ urls: [URL], _ index: Int?) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        insertion = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let index = grid?.insertionIndex(at: info.location)
        isTargeted = false
        insertion = nil
        let providers = info.itemProviders(for: [.fileURL])
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.url(from: provider) { urls.append(url) }
            }
            add(urls, index)
        }
        return true
    }

    private func update(_ info: DropInfo) {
        let index = grid?.insertionIndex(at: info.location)
        if index != insertion { withAnimation(Motion.snappy) { insertion = index } }
    }

    private static func url(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    /// The apps among `urls`, with Finder aliases and symbolic links followed.
    static func apps(in urls: [URL]) -> [LauncherApp] {
        urls.compactMap { url in
            let url = (try? URL(resolvingAliasFileAt: url)) ?? url
            let type = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentTypeKey]).contentType
            guard type?.conforms(to: .applicationBundle) == true else { return nil }
            let app = AppCatalog.app(at: url)
            return LauncherApp(path: app.path, bundleID: app.bundleID, name: app.name)
        }
    }
}
