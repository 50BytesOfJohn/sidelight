import AppKit
import Observation
import SidelightCore
import SwiftUI

/// The built-in window manager: switching it on, how tiles are spaced, and its shortcuts. Layout and shortcuts can be
/// set while it's off, ready for when it's on.
struct WindowManagerSettingsPane: View {
    @Environment(ConfigurationStore.self) private var store
    @State private var rectangle = RectangleWatch()
    /// A preset chosen over custom shortcuts, waiting for the person to say they may be replaced.
    @State private var pendingPreset: WindowManagerPreset?

    var body: some View {
        @Bindable var store = store
        let settings = store.configuration.windowManager

        Form {
            Section {
                Toggle(isOn: $store.configuration.windowManager.isEnabled) {
                    Text("Window manager")
                    Text("Move and resize the frontmost window with shortcuts")
                }
                if settings.isEnabled { AccessibilityAccessRow() }
            } footer: {
                if settings.isEnabled && rectangle.isRunning {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Rectangle is running. Where both use the same shortcut, both move the window.")
                            .foregroundStyle(.orange)
                            .settingsFootnote()
                        Spacer()
                        Button("Quit Rectangle") { rectangle.quit() }
                            .controlSize(.small)
                    }
                }
            }

            Section {
                spacingStepper("Gap between windows", value: $store.configuration.windowManager.gap)
                spacingStepper("Screen-edge padding", value: $store.configuration.windowManager.padding)
                Toggle("Repeat a half to cycle sizes", isOn: $store.configuration.windowManager.cyclesSizes)
            } header: {
                Text("Layout")
            } footer: {
                SettingsCaption(
                    "Pressing a half again within 0.7 s on the same window goes ½ → ⅓ → ⅔. Windows always stay "
                        + "clear of the panel, the same distance from it as window avoidance leaves.")
            }

            Section {
                Picker("Preset", selection: presetSelection(settings)) {
                    ForEach(WindowManagerPreset.allCases) { preset in
                        Text(preset.title).tag(Optional(preset))
                    }
                    if settings.preset == nil {
                        Text("Custom").tag(WindowManagerPreset?.none).selectionDisabled()
                    }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                SettingsCaption(
                    "A preset sets every shortcut below and which are on. Rectangle's also uses Magnet's keys for "
                        + "halves, maximize and center. Sidelight's is Rectangle's with the thirds off: cycling a "
                        + "half reaches them.")
            }

            ForEach(ShortcutCatalog.windowGroups, id: \.title) { group in
                if let footer = Self.footers[group.title] {
                    ShortcutSection(group.title, group.shortcuts, footer: footer)
                } else {
                    ShortcutSection(title: group.title, shortcuts: group.shortcuts) { EmptyView() }
                }
            }
        }
        .confirmationDialog(
            "Replace your custom window shortcuts?", isPresented: isConfirmingPreset, presenting: pendingPreset
        ) { preset in
            Button("Use \(preset.title)") { apply(preset) }
        } message: { preset in
            Text("Every window shortcut, and whether it's on, becomes \(preset.title)'s.")
        }
        .onAppear { rectangle.start() }
        .onDisappear { rectangle.stop() }
    }

    private static let footers = [
        "Thirds": "Left to right, or top to bottom on a portrait display.",
        "Size & Position": "Restore puts a window back where it was before the window manager first moved it.",
        "Displays": "Moving a window to another Space isn't possible without private macOS APIs.",
    ]

    private func spacingStepper(_ title: String, value: Binding<Int>) -> some View {
        Stepper(value: value, in: WindowLayout.spacingRange) {
            LabeledContent(title) {
                Text("\(value.wrappedValue) pt").monospacedDigit()
            }
        }
    }

    /// The preset in use, `nil` for custom shortcuts. Choosing one over custom shortcuts asks first.
    private func presetSelection(_ settings: WindowManagerSettings) -> Binding<WindowManagerPreset?> {
        Binding(
            get: { settings.preset },
            set: { preset in
                guard let preset, preset != settings.preset else { return }
                if settings.preset == nil { pendingPreset = preset } else { apply(preset) }
            })
    }

    private var isConfirmingPreset: Binding<Bool> {
        Binding(get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } })
    }

    /// Every window shortcut, in one change, so it's saved once.
    private func apply(_ preset: WindowManagerPreset) {
        store.configuration.windowManager.shortcuts = preset.shortcuts
        pendingPreset = nil
    }
}

/// Whether Rectangle or Rectangle Pro is running, while the pane showing it is open: both would act on a shortcut
/// they share with the window manager.
@Observable
private final class RectangleWatch {
    private(set) var isRunning = false
    @ObservationIgnored private var observations: [NotificationCenter.ObservationToken] = []

    func start() {
        refresh()
        guard observations.isEmpty else { return }
        let workspace = NSWorkspace.shared
        let center = workspace.notificationCenter
        observations = [
            center.addObserver(of: workspace, for: .didLaunchApplication) { [weak self] _ in self?.refresh() },
            center.addObserver(of: workspace, for: .didTerminateApplication) { [weak self] _ in self?.refresh() },
        ]
    }

    func stop() {
        for token in observations { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        observations = []
    }

    /// Asks it to quit, as quitting it from its menu would.
    func quit() {
        for application in running { application.terminate() }
    }

    private var running: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            RectangleIntegration.bundleIdentifiers.contains($0.bundleIdentifier ?? "")
        }
    }

    private func refresh() {
        let isRunning = !running.isEmpty
        if self.isRunning != isRunning { self.isRunning = isRunning }
    }
}
