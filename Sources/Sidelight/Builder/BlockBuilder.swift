import SidelightCore
import SwiftUI

/// A block as the builder lists it.
protocol DescribedBlock: WidgetBlockKind, Identifiable {
    var title: String { get }
    var systemImage: String { get }
    /// What it shows, in a line.
    var blurb: String { get }
}

/// A widget built from blocks, as its builder edits it. The widget's settings conform: their blocks, each block's
/// options, the options for the whole widget (where its data comes from, how often), and ready-made layouts.
protocol BlockBuiltWidget: Hashable {
    associatedtype Block: DescribedBlock
    associatedtype BlockOptions: View
    associatedtype WidgetOptions: View

    var blocks: BlockLayout<Block> { get set }

    /// Ready-made layouts to start from, the first being the default.
    static var presets: [BlockPreset<Block>] { get }

    /// One block's options; empty for a block without any.
    @ViewBuilder
    static func options(for block: Block, settings: Binding<Self>) -> BlockOptions

    /// Options for the whole widget, such as its account and how often it refreshes.
    @ViewBuilder
    static func widgetOptions(settings: Binding<Self>) -> WidgetOptions

    /// Blocks that can be added any number of times, each with its own options.
    static var addableBlocks: [AddableBlock] { get }

    /// Adds a block of the addable kind `id`, shown at the end, and returns it.
    mutating func addBlock(_ id: AddableBlock.ID) -> Block?

    /// Removes an added block, with its options. Fixed blocks can only be hidden.
    mutating func removeBlock(_ block: Block)

    /// What the builder calls `block`: an added block names what it shows.
    func title(of block: Block) -> String
}

extension BlockBuiltWidget {
    static var addableBlocks: [AddableBlock] { [] }

    mutating func addBlock(_ id: AddableBlock.ID) -> Block? { nil }

    mutating func removeBlock(_ block: Block) { blocks.remove(block) }

    func title(of block: Block) -> String { block.title }
}

/// A kind of block the builder offers to add, as many times as wanted.
struct AddableBlock: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let blurb: String
}

/// A ready-made layout: these blocks in this order, the rest hidden. Each block keeps its options.
struct BlockPreset<Block: WidgetBlockKind>: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let summary: String
    let blocks: [Block]

    func matches(_ layout: BlockLayout<Block>) -> Bool { layout.shownBlocks == blocks }
}

extension WidgetSettings {
    /// Whether this widget is built from blocks and has a builder.
    var hasBuilder: Bool {
        switch self {
        case .railway: true
        case .clock, .codex, .claudeCode, .cursor, .aiUsage, .calendar, .nowPlaying, .claudeSessions, .system,
            .noodleComputer:
            false
        }
    }
}

/// The builder window's content: the builder for the widget it was opened for. Every change applies to the live
/// panel immediately, as in the Widgets window.
struct WidgetBuilderWindow: View {
    @Environment(WindowCoordinator.self) private var windows
    @Environment(ConfigurationStore.self) private var store

    var body: some View {
        if let id = windows.builderWidgetID, let widget = store.configuration.widget(id) {
            switch widget.settings {
            case .railway(let settings):
                BlockBuilderView(
                    kind: widget.kind,
                    settings: binding(id, current: settings, embed: WidgetSettings.railway) {
                        if case .railway(let settings) = $0 { settings } else { nil }
                    },
                    embed: WidgetSettings.railway)
            case .clock, .codex, .claudeCode, .cursor, .aiUsage, .calendar, .nowPlaying, .claudeSessions, .system,
                .noodleComputer:
                ContentUnavailableView(
                    "No builder", systemImage: "square.stack.3d.up.slash",
                    description: Text("This widget's options are in the Widgets window."))
            }
        } else {
            ContentUnavailableView(
                "Widget removed", systemImage: "square.dashed",
                description: Text("The widget this builder was editing is no longer in the panel."))
        }
    }

    /// Looks the widget up by identity on every access, so edits never land on another widget.
    private func binding<Settings>(
        _ id: WidgetInstance.ID, current: Settings, embed: @escaping (Settings) -> WidgetSettings,
        extract: @escaping (WidgetSettings) -> Settings?
    ) -> Binding<Settings> {
        Binding {
            store.configuration.widget(id).flatMap { extract($0.settings) } ?? current
        } set: { updated in
            store.configuration.updateWidget(id) { $0.settings = embed(updated) }
        }
    }
}

/// What the builder's inspector shows.
private enum BuilderSelection<Block: Hashable>: Hashable {
    case widget
    case block(Block)
}

/// Blocks on the left, the widget live at every size in the middle, and the selected block's options on the right.
struct BlockBuilderView<Widget: BlockBuiltWidget>: View {
    let kind: WidgetKind
    @Binding var settings: Widget
    let embed: (Widget) -> WidgetSettings
    @State private var selection: BuilderSelection<Widget.Block>? = .widget

    var body: some View {
        HStack(spacing: 0) {
            blockList.frame(width: 290)
            Divider()
            preview.frame(maxWidth: .infinity)
            Divider()
            inspector.frame(width: 330)
        }
        .background(.background)
    }

    // MARK: Blocks

    private var shown: [Widget.Block] { settings.blocks.shownBlocks }
    private var hidden: [Widget.Block] { settings.blocks.entries.filter { !$0.isShown }.map(\.block) }

    private var blockList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ColumnHeader(title: kind.metadata.title, subtitle: "Arrange its blocks · changes apply live")
                presetsMenu
            }
            .padding(.horizontal, 16)
            .padding(.top, 34)
            .padding(.bottom, 8)

            List(selection: $selection) {
                Label {
                    Text("Widget").font(.system(size: 12.5, weight: .medium))
                } icon: {
                    kind.metadata.iconTile(size: 22)
                }
                .tag(BuilderSelection<Widget.Block>.widget)

                Section("Shown") {
                    if shown.isEmpty {
                        Text("Nothing yet: add a block below.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(shown) { block in
                        BlockRow(block: block, title: settings.title(of: block), isShown: true) {
                            setShown(block, false)
                        }
                        .tag(BuilderSelection<Widget.Block>.block(block))
                        .contextMenu { removeButton(block) }
                    }
                    .onMove { source, destination in
                        var order = shown
                        order.move(fromOffsets: source, toOffset: destination)
                        withAnimation(Motion.layout) { settings.blocks.reorderShown(order) }
                    }
                }
                if !hidden.isEmpty || !Widget.addableBlocks.isEmpty {
                    Section("More blocks") {
                        ForEach(hidden) { block in
                            BlockRow(block: block, title: settings.title(of: block), isShown: false) {
                                setShown(block, true)
                            }
                            .tag(BuilderSelection<Widget.Block>.block(block))
                            .contextMenu { removeButton(block) }
                        }
                        ForEach(Widget.addableBlocks) { addable in
                            AddableBlockRow(addable: addable) { add(addable) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Text("Drag shown blocks to reorder them. Hidden blocks keep their options; + adds another.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
        }
    }

    private var presetsMenu: some View {
        Menu {
            ForEach(Widget.presets) { preset in
                Button {
                    withAnimation(Motion.layout) { settings.blocks.showOnly(preset.blocks) }
                } label: {
                    Label {
                        Text(preset.title)
                        Text(preset.summary)
                    } icon: {
                        Image(systemName: preset.matches(settings.blocks) ? "checkmark" : preset.systemImage)
                    }
                }
            }
        } label: {
            Label(currentPreset?.title ?? "Custom layout", systemImage: "rectangle.stack")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Start from a ready-made layout. Each block keeps its options.")
    }

    private var currentPreset: BlockPreset<Widget.Block>? {
        Widget.presets.first { $0.matches(settings.blocks) }
    }

    private func setShown(_ block: Widget.Block, _ isShown: Bool) {
        withAnimation(Motion.layout) { settings.blocks.setShown(block, isShown) }
        selection = .block(block)
    }

    private func add(_ addable: AddableBlock) {
        var updated = settings
        guard let block = updated.addBlock(addable.id) else { return }
        withAnimation(Motion.layout) { settings = updated }
        selection = .block(block)
    }

    private func remove(_ block: Widget.Block) {
        if selection == .block(block) { selection = .widget }
        withAnimation(Motion.layout) { settings.removeBlock(block) }
    }

    @ViewBuilder
    private func removeButton(_ block: Widget.Block) -> some View {
        if !block.isFixed {
            Button("Remove", systemImage: "trash", role: .destructive) { remove(block) }
        }
    }

    // MARK: Preview

    private var preview: some View {
        let widget = embed(settings)
        return ZStack {
            PreviewStage().ignoresSafeArea()
            ScrollView {
                VStack(spacing: 26) {
                    stage("Regular") { WidgetPreview(settings: widget, layout: .regular) }
                    HStack(alignment: .top, spacing: 26) {
                        stage("Compact") { WidgetPreview(settings: widget, layout: .compact) }
                        stage("Minimal") { WidgetPreview(settings: widget, layout: .minimal) }
                    }
                    stage("Bar") { WidgetPreview(settings: widget, layout: .bar) }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func stage(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(.white.opacity(0.55))
            content()
        }
    }

    // MARK: Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch selection {
                case .block(let block):
                    blockInspector(block)
                case .widget, nil:
                    InspectorHeader(
                        title: kind.metadata.title, subtitle: "Where its data comes from, and how often it refreshes"
                    ) {
                        kind.metadata.iconTile(size: 44)
                    }
                    InspectorSection("Widget") {
                        Widget.widgetOptions(settings: $settings)
                    }
                }
            }
            .padding(18)
            .padding(.top, 20)
            .id(selection)
            .transition(.opacity.combined(with: .offset(x: 12)))
        }
        .animation(Motion.snappy, value: selection)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private func blockInspector(_ block: Widget.Block) -> some View {
        InspectorHeader(title: settings.title(of: block), subtitle: block.blurb) {
            IconTile(systemImage: block.systemImage, tint: kind.metadata.tint, size: 44)
        }
        InspectorSection("Block") {
            Toggle(
                "Show in the widget",
                isOn: Binding {
                    settings.blocks.isShown(block)
                } set: { isShown in
                    withAnimation(Motion.layout) { settings.blocks.setShown(block, isShown) }
                })
            if settings.blocks.isShown(block) {
                HStack {
                    Button("Move Up", systemImage: "arrow.up") { move(block, by: -1) }
                        .disabled(shown.first == block)
                    Button("Move Down", systemImage: "arrow.down") { move(block, by: 1) }
                        .disabled(shown.last == block)
                }
                .controlSize(.small)
            }
        }
        InspectorSection("Options") {
            Widget.options(for: block, settings: $settings)
        }
        if !block.isFixed {
            Button(role: .destructive) {
                remove(block)
            } label: {
                Label("Remove Block", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    private func move(_ block: Widget.Block, by offset: Int) {
        withAnimation(Motion.layout) { settings.blocks.moveAmongShown(block, by: offset) }
    }
}

private struct BlockRow<Block: DescribedBlock>: View {
    let block: Block
    let title: String
    let isShown: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: block.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.08)))
                .foregroundStyle(isShown ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isShown ? .primary : .secondary)
                    .lineLimit(1)
                Text(block.blurb)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: toggle) {
                Image(systemName: isShown ? "eye" : "plus.circle.fill")
                    .foregroundStyle(isShown ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help(isShown ? "Hide this block" : "Show this block")
        }
        .padding(.vertical, 2)
    }
}

/// A kind of block that can be added again and again, with a button that adds one.
private struct AddableBlockRow: View {
    let addable: AddableBlock
    let add: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: addable.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                )
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Add \(addable.title)").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                Text(addable.blurb).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: add) {
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help("Add a \(addable.title) block")
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: add)
    }
}

/// The icon, title and subtitle at the top of an inspector.
struct InspectorHeader<Icon: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 18, weight: .bold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
