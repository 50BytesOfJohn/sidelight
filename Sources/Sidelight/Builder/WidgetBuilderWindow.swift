import SidelightCore
import SwiftUI

/// The builder window's content: the builder for the widget it was opened for. Every change applies to the live
/// panel immediately, as in the Widgets window.
struct WidgetBuilderWindow: View {
    @Environment(WindowCoordinator.self) private var windows
    @Environment(ConfigurationStore.self) private var store

    var body: some View {
        Group {
            if let id = windows.builderWidgetID, let widget = store.configuration.widget(id) {
                switch widget.settings {
                case .railway(let settings): builder(id, current: settings, embed: WidgetSettings.railway)
                case .codexSessions(let settings): builder(id, current: settings, embed: WidgetSettings.codexSessions)
                case .openRouter(let settings): builder(id, current: settings, embed: WidgetSettings.openRouter)
                case .aiUsage(let settings): builder(id, current: settings, embed: WidgetSettings.aiUsage)
                case .clock, .codex, .claudeCode, .cursor, .calendar, .nowPlaying, .claudeSessions, .system,
                    .noodleComputer, .agentSessions, .stash, .awake, .docker, .appLauncher:
                    removed
                }
            } else {
                removed
            }
        }
        // Clocks in the preview stop while the window is covered, minimized or on another Space.
        .environment(\.isPanelShown, windows.isBuilderVisible)
    }

    private var removed: some View {
        ContentUnavailableView("Widget removed", systemImage: "square.dashed")
    }

    /// A builder whose edits look the widget up by identity on every access, so they never land on another widget,
    /// or on settings of another kind. A new one for each widget: a block selected in another doesn't exist in this
    /// one.
    private func builder<Settings: BlockBuiltWidget>(
        _ id: WidgetInstance.ID, current: Settings, embed: @escaping (Settings) -> WidgetSettings
    ) -> some View {
        BlockBuilderView(
            settings: Binding {
                store.configuration.widget(id)?.settings.blockBuilt as? Settings ?? current
            } set: { updated in
                // A widget whose settings are now of another kind, edited elsewhere, keeps them.
                store.configuration.updateWidget(id) { widget in
                    if widget.settings.blockBuilt is Settings { widget.settings = embed(updated) }
                }
            },
            embed: embed
        )
        .id(id)
    }
}

/// What the builder's inspector edits: the whole widget, or one of its blocks.
enum BuilderSelection<Block: Hashable>: Hashable {
    case widget
    case block(Block)
}

/// The widget's blocks in the sidebar, the widget itself on the stage, and the selection's options in the inspector,
/// laid out like the Widgets window.
private struct BlockBuilderView<Widget: BlockBuiltWidget>: View {
    @Binding var settings: Widget
    let embed: (Widget) -> WidgetSettings
    @State private var selection: BuilderSelection<Widget.Block>? = .widget
    @State private var pendingRemoval: Widget.Block?
    @State private var isInspectorShown = true
    @AppStorage("BuilderPreviewLayout") private var previewLayout = WidgetLayout.regular
    @Environment(ConfigurationStore.self) private var store

    var body: some View {
        let widget = embed(settings)
        let editor = BlockEditor(settings: $settings, selection: $selection, pendingRemoval: $pendingRemoval)
        NavigationSplitView {
            BlockSidebar(widget: widget, editor: editor)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            BuilderStage(
                settings: widget, layout: previewLayout,
                appearance: CardAppearance(store.configuration.appearance).forPreview
            )
            .equatable()
            .toolbar { toolbar }
            .inspector(isPresented: $isInspectorShown) {
                BuilderInspector(kind: widget.kind, editor: editor)
                    .inspectorColumnWidth(min: 300, ideal: 330, max: 440)
            }
        }
        .onChange(of: selection) {
            if selection != nil { isInspectorShown = true }
        }
        // Removing a block deletes its options too, such as its account and title, so it asks first.
        .confirmationDialog(
            pendingRemoval.map { "Remove \u{201C}\(settings.title(of: $0))\u{201D}?" } ?? "",
            isPresented: Binding {
                pendingRemoval != nil
            } set: { isPresented in
                if !isPresented { pendingRemoval = nil }
            },
            presenting: pendingRemoval
        ) { block in
            Button("Remove", role: .destructive) { editor.remove(block) }
        } message: { _ in
            Text("This also deletes its options.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Size", selection: $previewLayout.animation(Motion.layout)) {
                ForEach(WidgetLayout.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // One icon, as in the Widgets window: a toolbar drops a menu's text. The menu ticks the layout shown.
            Menu {
                BlockPresetPicker(settings: $settings.animation(Motion.layout))
                    .pickerStyle(.inline)
                    .labelsHidden()
            } label: {
                Label("Layout", systemImage: "rectangle.3.group")
            }
            .menuIndicator(.hidden)
            .help("Ready-made layouts")
            Button {
                isInspectorShown.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(isInspectorShown ? "Hide the inspector" : "Show the inspector")
        }
    }
}

/// The widget at the size chosen in the toolbar, centered on the preview stage. The stage reaches under the sidebar
/// and the inspector, and a widget taller than the window scrolls.
///
/// Equatable, so it redraws only when what it shows changes, not for a new selection or an edit to another widget.
private struct BuilderStage: View, Equatable {
    let settings: WidgetSettings
    let layout: WidgetLayout
    let appearance: CardAppearance

    var body: some View {
        ScrollView {
            WidgetPreview(settings: settings, layout: layout, appearance: appearance)
                .padding(40)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollBounceBehavior(.basedOnSize)
        .background { PreviewStage().backgroundExtensionEffect() }
    }
}
