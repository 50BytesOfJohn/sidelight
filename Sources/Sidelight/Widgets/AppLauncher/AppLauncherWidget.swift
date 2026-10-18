import AppKit
import SidelightCore
import SwiftUI
import UniformTypeIdentifiers

extension WidgetMetadata {
    static let appLauncher = WidgetMetadata(
        title: "App Launcher",
        systemImage: "square.grid.3x3.fill",
        tint: .indigo,
        summary: "Your apps, one click away",
        details: "Opens apps, and brings running ones forward, like the Dock. Running apps get a dot. Sidelight "
            + "is told when apps open and quit, and never checks on a timer. New Window needs Accessibility access."
    )
}

extension AppLauncherSettings {
    var summary: String {
        guard !apps.isEmpty else { return "Empty" }
        let count = apps.count == 1 ? "1 app" : "\(apps.count) apps"
        return "\(count) · \(columns == 0 ? "auto" : "\(columns) columns")"
    }
}

// MARK: - Widget

struct AppLauncherWidgetView: View {
    let settings: AppLauncherSettings
    let layout: WidgetLayout
    @Environment(AppLauncherService.self) private var service
    @Environment(DetailsPresenter.self) private var details
    @Environment(ConfigurationStore.self) private var store
    @Environment(AccessibilityPermission.self) private var accessibility
    @Environment(\.widgetPlacement) private var placement
    @Environment(\.isWidgetPreview) private var isPreview
    /// The content's width, measured once and again only when the panel resizes.
    @State private var width: Double?
    @State private var insertion: Int?
    @State private var isTargeted = false

    var body: some View {
        let apps = isPreview && settings.apps.isEmpty ? AppLauncherSettings.sample.apps : settings.apps
        Group {
            if apps.isEmpty && !layout.isGlanceable {
                WidgetMessage(
                    title: "No apps yet", detail: "Drop apps here, or choose some from All Apps.",
                    systemImage: "square.grid.3x3", layout: layout,
                    action: WidgetMessage.Action(
                        title: "Choose Apps…", isDisabled: placement == nil || isPreview,
                        run: { showAllApps(scope: .all) })
                )
                .onDrop(of: [.fileURL], delegate: dropDelegate(grid: nil))
            } else {
                content(apps)
            }
        }
        // The bar's chip keeps to its icons; the other layouts measure the column's width. `minWidth: 0` makes the
        // frame take the width it's offered, not its content's: a grid laid out for a guessed, wider width would
        // otherwise measure itself and keep overflowing the card.
        .frame(minWidth: layout == .bar ? nil : 0, maxWidth: layout == .bar ? nil : .infinity)
        .onGeometryChange(for: Double.self) {
            $0.size.width
        } action: {
            width = $0
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(WidgetMetadata.appLauncher.tint, lineWidth: 1.5)
                    .padding(-4)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func content(_ apps: [LauncherApp]) -> some View {
        let items = apps.map { LauncherItem(pinned: $0, service: service) }
        switch layout {
        case .regular, .compact: grid(items)
        case .minimal: column(items)
        case .bar: bar(items)
        }
    }

    // MARK: Layouts

    private func grid(_ pinned: [LauncherItem]) -> some View {
        let isRegular = layout == .regular
        let iconSize = Double(isRegular ? settings.iconSize : min(settings.iconSize, 28))
        let spacing = isRegular ? settings.spacing.points : settings.spacing.compactPoints
        let showsNames = isRegular && settings.showsNames
        let extras =
            settings.showsRunningApps && !isPreview
            ? service.unpinned(excluding: settings.apps).map(LauncherItem.init(running:)) : []
        let grid = LauncherGrid(
            LauncherGrid.Input(
                width: width ?? (isRegular ? 244 : 148), iconSize: iconSize, spacing: spacing,
                fixedColumns: settings.columns, rowLimit: settings.rows, pinnedCount: pinned.count,
                extraCount: extras.count, showsAllAppsTile: settings.showsAllAppsTile,
                labelHeight: showsNames ? 13 : 0))
        return VStack(alignment: .leading, spacing: grid.spacing) {
            ForEach(Array(grid.rows.enumerated()), id: \.offset) { index, row in
                if index == grid.dividerBeforeRow {
                    HairlineDivider().frame(width: grid.width)
                }
                HStack(spacing: grid.spacing) {
                    ForEach(row, id: \.self) { cell in
                        self.cell(
                            cell, pinned: pinned, extras: extras, overflow: grid.overflow, size: iconSize,
                            cellWidth: grid.cellSize, showsNames: showsNames)
                    }
                }
            }
        }
        .frame(width: grid.width, alignment: .leading)
        .overlay(alignment: .topLeading) { insertionMarker(grid) }
        .onDrop(of: [.fileURL], delegate: dropDelegate(grid: grid))
        .animation(Motion.layout, value: pinned.map(\.id) + extras.map(\.id))
    }

    private func column(_ items: [LauncherItem]) -> some View {
        let size = (width ?? 56) < 60 ? 28.0 : 32.0
        let grid = LauncherGrid.column(
            count: items.count, rowLimit: settings.rows, showsAllAppsTile: settings.showsAllAppsTile || items.isEmpty)
        return VStack(spacing: 4) {
            ForEach(grid.rows.flatMap(\.self), id: \.self) { cell in
                self.cell(cell, pinned: items, extras: [], overflow: grid.overflow, size: size)
            }
        }
        .onDrop(of: [.fileURL], delegate: dropDelegate(grid: nil))
    }

    private func bar(_ items: [LauncherItem]) -> some View {
        let grid = LauncherGrid.bar(
            count: items.count, limit: settings.barCount, showsAllAppsTile: settings.showsAllAppsTile || items.isEmpty)
        return HStack(spacing: 4) {
            ForEach(grid.rows.flatMap(\.self), id: \.self) { cell in
                self.cell(cell, pinned: items, extras: [], overflow: grid.overflow, size: 24)
            }
        }
        .onDrop(of: [.fileURL], delegate: dropDelegate(grid: nil))
    }

    @ViewBuilder
    private func cell(
        _ cell: LauncherGrid.Cell, pinned: [LauncherItem], extras: [LauncherItem], overflow: Int, size: Double,
        cellWidth: CGFloat? = nil, showsNames: Bool = false
    ) -> some View {
        switch cell {
        case .pinned(let index):
            icon(pinned[index], size: size, cellWidth: cellWidth, showsNames: showsNames)
        case .extra(let index):
            icon(extras[index], size: size, cellWidth: cellWidth, showsNames: showsNames)
        case .tile:
            AllAppsTile(
                overflow: overflow, size: size, cellWidth: cellWidth, open: allAppsAction,
                help: settings.apps.isEmpty ? "Drop apps here, or choose some from All Apps" : "All apps")
        }
    }

    private func icon(_ item: LauncherItem, size: Double, cellWidth: CGFloat?, showsNames: Bool) -> some View {
        LauncherIcon(
            item: item, size: size, showsDot: settings.showsRunningIndicator, label: showsNames, cellWidth: cellWidth,
            isLaunching: item.pinned.map { service.launching.contains($0.id) } ?? false, actions: actions)
    }

    /// A thin bar in the gap a drop would land in.
    @ViewBuilder
    private func insertionMarker(_ grid: LauncherGrid) -> some View {
        if let insertion, grid.columns > 0 {
            let row = insertion / grid.columns
            let column = insertion % grid.columns
            // The end of a full row is the start of the next one; it's drawn after the row's last icon.
            let atRowEnd = column == 0 && insertion > 0 && insertion == grid.visiblePinned
            let drawnRow = atRowEnd ? row - 1 : row
            let drawnColumn = atRowEnd ? grid.columns : column
            let x = Double(drawnColumn) * (grid.cellSize + grid.spacing) - grid.spacing / 2 - 1
            Capsule()
                .fill(WidgetMetadata.appLauncher.tint)
                .frame(width: 2, height: grid.rowHeight)
                .offset(x: max(x, -1), y: Double(drawnRow) * (grid.rowHeight + grid.spacing))
                .allowsHitTesting(false)
        }
    }

    // MARK: Actions

    /// Only from a real panel: previews never open anything, or change the configuration.
    private var actions: LauncherItemActions? {
        guard let placement, !isPreview else { return nil }
        return LauncherItemActions(
            service: service,
            edit: { [store] change in store.configuration.updateAppLauncher(placement.widgetID, change) },
            showAllApps: { showAllApps(scope: .pinned) }, canPressMenus: accessibility.isTrusted)
    }

    private var allAppsAction: (() -> Void)? {
        guard placement != nil, !isPreview else { return nil }
        return { showAllApps(scope: settings.apps.isEmpty ? .all : .pinned) }
    }

    private func showAllApps(scope: LauncherScope) {
        guard let placement, !isPreview else { return }
        details.open(.appLauncher(widget: placement.widgetID, scope: scope), from: placement)
    }

    private func dropDelegate(grid: LauncherGrid?) -> LauncherDropDelegate {
        LauncherDropDelegate(
            isEnabled: placement != nil && !isPreview, grid: grid, insertion: $insertion, isTargeted: $isTargeted
        ) { urls, index in
            guard let placement, !isPreview else { return }
            let apps = LauncherDropDelegate.apps(in: urls)
            var added = 0
            store.configuration.updateAppLauncher(placement.widgetID) { added = $0.add(apps, at: index) }
            if added == 0 { NSSound.beep() }
        }
    }
}
