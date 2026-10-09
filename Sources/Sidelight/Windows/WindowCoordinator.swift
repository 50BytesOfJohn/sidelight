import AppKit
import Observation
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

    /// The manager shows live previews of every widget, so its data services must run while it's open.
    private(set) var isManagerOpen = false

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var windows: [Kind: NSWindow] = [:]

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func show(_ kind: Kind) {
        let window = windows[kind] ?? makeWindow(kind)
        windows[kind] = window
        isManagerOpen = windows[.manager] != nil
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activateForcingForeground()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Shows `kind` in place of the other window, for the links between them (see ``WindowSwitchLink``).
    func switchTo(_ kind: Kind) {
        let others = windows.filter { $0.key != kind }.values
        show(kind)
        for window in others { window.close() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let kind = windows.first(where: { $0.value === window })?.key
        else { return }
        // Tear down after AppKit has finished closing the window.
        Task {
            window.contentView = nil
            windows[kind] = nil
            isManagerOpen = windows[.manager] != nil
            if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
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
