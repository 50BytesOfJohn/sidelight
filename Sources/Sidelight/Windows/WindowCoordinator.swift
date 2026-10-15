import AppKit
import Observation
import SidelightCore
import SwiftUI

/// Opens the Widgets manager and Settings windows for an accessory (menu-bar-only) app.
///
/// For these windows to come to the front and accept typing, the app must:
///  1. switch to the `.regular` activation policy while any of them is open (Dock icon, ⌘-Tab entry),
///  2. activate itself, then make the window key,
///  3. have a main menu with an Edit menu, or ⌘C/⌘V/⌘A won't work in text fields (see ``MainMenu``),
///  4. return to `.accessory` after the last one closes, dropping the SwiftUI tree so its memory is released.
@Observable
final class WindowCoordinator: NSObject, NSWindowDelegate {
    enum Kind {
        case manager, settings
    }

    /// The manager shows live previews of every widget, so their data services must run while it can be seen, and
    /// for a minute after it's covered, minimized or left on another Space, so glancing away doesn't restart them.
    private(set) var previewsEveryWidget = false
    /// Whether the manager can be seen right now. Its previews stop redrawing with the clock while it can't.
    private(set) var isManagerVisible = false
    /// The widget the builder window edits, while it's open. It previews only that widget, so only that widget's
    /// data services run for it.
    private(set) var builderWidgetID: WidgetInstance.ID?
    /// Whether the builder can be seen right now. Its preview stops redrawing with the clock while it can't.
    private(set) var isBuilderVisible = false
    /// A widget for the Widgets window to select once it shows, opened from somewhere else.
    private(set) var managerSelectionRequest: WidgetInstance.ID?

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var windows: [Kind: NSWindow] = [:]
    /// The builder: one window, for whichever widget it was last opened for.
    @ObservationIgnored private var builderWindow: NSWindow?
    @ObservationIgnored private let stopsPreviews = DelayedTask()
    /// The strips the panels keep clear. Sidelight's windows open beside them, never under them.
    @ObservationIgnored var occupiedRegions: () -> [PanelRegion] = { [] }
    @ObservationIgnored private let pendingClearance = DelayedTask()

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func show(_ kind: Kind) {
        let window = windows[kind] ?? makeWindow(kind)
        windows[kind] = window
        bringToFront(window)
    }

    /// Opens where the widget with `id` is set up: its builder, for a widget built from blocks, otherwise the Widgets
    /// window with the widget selected.
    func showSettings(forWidget id: WidgetInstance.ID) {
        guard let widget = environment.configurationStore.configuration.widget(id) else { return }
        if widget.settings.hasBuilder {
            showBuilder(for: widget)
        } else {
            managerSelectionRequest = id
            show(.manager)
        }
    }

    /// Hands the Widgets window the widget it was asked to select, once.
    func takeManagerSelectionRequest() -> WidgetInstance.ID? {
        defer { managerSelectionRequest = nil }
        return managerSelectionRequest
    }

    /// Opens the builder for `widget`, in place of the one it was editing.
    func showBuilder(for widget: WidgetInstance) {
        let title = "\(widget.kind.metadata.title) Builder"
        builderWidgetID = widget.id
        let window =
            builderWindow
            ?? makeWindow(
                title: title,
                size: NSSize(width: 1080, height: 720),
                minimumSize: NSSize(width: 880, height: 540),
                autosaveName: "BuilderWindow",
                rootView: WidgetBuilderWindow()
            )
        window.title = title
        builderWindow = window
        bringToFront(window)
    }

    private func bringToFront(_ window: NSWindow) {
        keepClearOfPanels(window)
        updatePreviews()
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activateForcingForeground()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Moves the open windows out from under a panel that moved or grew, once it has settled: switching the panel
    /// to the other edge from Settings shouldn't bury Settings.
    func panelsChanged(settlingFor delay: Duration?) {
        let keepClear = { [weak self] in
            guard let self else { return }
            for window in Array(windows.values) + [builderWindow].compactMap(\.self) { keepClearOfPanels(window) }
        }
        if let delay { pendingClearance.schedule(after: delay, keepClear) } else { keepClear() }
    }

    /// Sidelight's floating panel would cover its own window on a small screen: move the window beside it, and
    /// shrink it if it must. Window avoidance only moves other apps' windows.
    private func keepClearOfPanels(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        // Not the details panel: it's open only for a moment, and nothing would put the window back after.
        let panels = occupiedRegions().filter { $0.role == .main && $0.displayFrame == screen.frame }.map(\.frame)
        let free = OwnWindowPlacement.freeFrame(in: screen.visibleFrame, beside: panels)
        let frame = OwnWindowPlacement.fit(
            window.frame, minimumSize: window.minSize, in: free, visibleFrame: screen.visibleFrame)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    private func updatePreviews() {
        let isBuilderVisible = builderWindow?.occlusionState.contains(.visible) ?? false
        if isBuilderVisible != self.isBuilderVisible { self.isBuilderVisible = isBuilderVisible }
        let manager = windows[.manager]
        let isVisible = manager?.occlusionState.contains(.visible) ?? false
        if isVisible != isManagerVisible { isManagerVisible = isVisible }
        if isVisible {
            stopsPreviews.cancel()
            if !previewsEveryWidget { previewsEveryWidget = true }
        } else if manager == nil {
            stopsPreviews.cancel()
            if previewsEveryWidget { previewsEveryWidget = false }
        } else if previewsEveryWidget && !stopsPreviews.isPending {
            stopsPreviews.schedule(after: .seconds(60), tolerance: .seconds(5)) { [weak self] in
                self?.previewsEveryWidget = false
            }
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === windows[.manager] || window === builderWindow
        else { return }
        updatePreviews()
    }

    /// Shows `kind` in place of the other window, for the links between them (see ``WindowSwitchLink``).
    func switchTo(_ kind: Kind) {
        let others = windows.filter { $0.key != kind }.values
        show(kind)
        for window in others { window.close() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let kind = windows.first(where: { $0.value === window })?.key
        guard kind != nil || window === builderWindow else { return }
        // Tear down after AppKit has finished closing the window.
        Task {
            window.contentView = nil
            if let kind {
                windows[kind] = nil
            } else {
                builderWindow = nil
                builderWidgetID = nil
            }
            updatePreviews()
            if windows.isEmpty && builderWindow == nil { NSApp.setActivationPolicy(.accessory) }
        }
    }

    private func makeWindow(_ kind: Kind) -> NSWindow {
        switch kind {
        case .manager:
            makeWindow(
                title: "Widgets",
                size: NSSize(width: 1180, height: 760),
                minimumSize: NSSize(width: 1040, height: 640),
                autosaveName: "WidgetsWindow",
                rootView: ManagerView()
            )
        case .settings:
            makeWindow(
                title: "Sidelight Settings",
                size: NSSize(width: 780, height: 680),
                minimumSize: NSSize(width: 700, height: 520),
                autosaveName: "SettingsWindow",
                rootView: SettingsView()
            )
        }
    }

    private func makeWindow(
        title: String,
        size: NSSize,
        minimumSize: NSSize,
        autosaveName: String,
        rootView: some View
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = minimumSize
        window.contentView = NSHostingView(rootView: rootView.environment(environment).environment(self))
        window.center()
        window.setFrameAutosaveName(autosaveName)
        window.delegate = self
        window.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        return window
    }
}

/// A row at the bottom of a window's sidebar that switches to the other window: Widgets ↔ Settings.
struct WindowSwitchLink: View {
    let destination: WindowCoordinator.Kind
    @Environment(WindowCoordinator.self) private var windows
    @State private var isHovered = false

    var body: some View {
        Button {
            windows.switchTo(destination)
        } label: {
            HStack(spacing: 8) {
                IconTile(systemImage: systemImage, tint: tint, size: 22)
                Text(title)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(isHovered ? 1 : 0.6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Motion.snappy) { isHovered = hovering } }
        .help(help)
    }

    private var title: String {
        switch destination {
        case .manager: "Widgets"
        case .settings: "Settings"
        }
    }

    private var systemImage: String {
        switch destination {
        case .manager: "square.grid.2x2.fill"
        case .settings: "gearshape.fill"
        }
    }

    private var tint: Color {
        switch destination {
        case .manager: .purple
        case .settings: .gray
        }
    }

    private var help: String {
        switch destination {
        case .manager: "Switch to the Widgets window (⌘1)"
        case .settings: "Switch to the Settings window (⌘,)"
        }
    }
}
