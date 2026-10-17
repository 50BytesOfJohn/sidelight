import SidelightCore
import SwiftUI

/// The selected widget's settings and previews at every size, or the selected section's size and alignment.
struct InspectorColumn: View {
    @Binding var selection: ManagerSelection?
    @Environment(ConfigurationStore.self) private var store

    var body: some View {
        let configuration = store.configuration
        Group {
            switch selection {
            case .widget(let id):
                if let widget = configuration.widget(id) {
                    inspector(id: id) {
                        WidgetInspector(widget: binding(for: widget), onRemove: { remove(id) })
                    }
                } else {
                    placeholder
                }
            case .section(let id):
                if let section = configuration.section(id) {
                    inspector(id: id) {
                        SectionInspector(
                            section: binding(for: section),
                            onSelect: { selection = .section($0) },
                            onRemove: configuration.sections.count > 1 ? { removeSection(id) } : nil)
                    }
                } else {
                    placeholder
                }
            case nil:
                placeholder
            }
        }
    }

    private func inspector(id: UUID, @ViewBuilder content: () -> some View) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .id(id)
    }

    private var placeholder: some View {
        ContentUnavailableView {
            Label("Nothing selected", systemImage: "square.grid.2x2")
        } description: {
            Text("Select a widget or a section in your panel to change it.")
        }
    }

    /// Looks the widget up by identity on every access, so edits never land on the wrong one after a reorder.
    private func binding(for widget: WidgetInstance) -> Binding<WidgetInstance> {
        Binding {
            store.configuration.widget(widget.id) ?? widget
        } set: { updated in
            store.configuration.updateWidget(widget.id) { $0 = updated }
        }
    }

    private func binding(for section: PanelSection) -> Binding<PanelSection> {
        Binding {
            store.configuration.section(section.id) ?? section
        } set: { updated in
            store.configuration.updateSection(section.id) { $0 = updated }
        }
    }

    private func remove(_ id: WidgetInstance.ID) {
        withAnimation(Motion.layout) { store.configuration.removeWidget(id) }
        selection = nil
    }

    private func removeSection(_ id: PanelSection.ID) {
        withAnimation(Motion.layout) { store.configuration.removeSection(id) }
        selection = nil
    }
}

/// A section's name, size and alignment.
private struct SectionInspector: View {
    @Binding var section: PanelSection
    /// `nil` while it's the only section, which can't be removed.
    let onSelect: (PanelSection.ID) -> Void
    let onRemove: (() -> Void)?
    @Environment(ConfigurationStore.self) private var store
    @Environment(DisplayMonitor.self) private var monitor

    var body: some View {
        let configuration = store.configuration
        let position = configuration.panel.position
        let fittedPanels = monitor.displays.map { $0.panel(in: configuration) }.filter { $0.showsPanel }
            .filter { $0.length == .fit }
        Section {
            SectionsPreview(selectedID: section.id, position: position, onSelect: onSelect)
                .padding(.vertical, 6)
        } header: {
            InspectorTitle(
                title: configuration.title(of: section),
                subtitle: section.widgets.count == 1 ? "1 widget" : "\(section.widgets.count) widgets"
            ) {
                IconTile(systemImage: "rectangle.split.1x2", tint: .gray, size: 32)
            } accessories: {
                InfoButton("Click a section to select it. Drag the line between two shared sections to resize them.")
            }
        }

        Section {
            TextField(
                text: Binding {
                    section.name ?? ""
                } set: {
                    section.name = $0.isEmpty ? nil : $0
                },
                prompt: Text(configuration.title(of: PanelSection(id: section.id)))
            ) {
                InfoLabel("Name", info: "Only shown here, to tell sections apart.")
            }
            Picker(selection: isShared.animation(Motion.layout)) {
                Text("Fit widgets").tag(false)
                Text("Share space").tag(true)
            } label: {
                InfoLabel(
                    "Size",
                    info: section.isShared
                        ? "Shared sections split the space that fitting sections leave, by weight. Two sections "
                            + "weighing 1 each get half each."
                        : "As long as its widgets, however long the panel is.")
            }
            .pickerStyle(.segmented)
            if let share = section.share, section.isShared {
                Stepper(value: shareBinding.animation(Motion.layout), in: 0.1...10, step: 0.5) {
                    LabeledContent("Weight") {
                        Text(
                            "\(share.formatted(.number.precision(.fractionLength(0...1)))) · "
                                + configuration.sizeSummary(of: section).lowercased())
                    }
                }
            }
            Picker(selection: $section.alignment.animation(Motion.layout)) {
                ForEach(PanelAlignment.allCases) { alignment in
                    Text(alignment.title(for: position)).tag(alignment)
                }
            } label: {
                InfoLabel(
                    "Alignment",
                    info: "Where the widgets sit when the section is longer than they are."
                        + (fittedPanels.isEmpty
                            ? ""
                            : " Where the panel fits its content, sections stack at their natural length, so size "
                                + "and alignment apply only where the panel fills its edge."))
            }
            .pickerStyle(.segmented)
        }

        if let onRemove {
            Section {
                Button("Remove Section", role: .destructive, action: onRemove)
                    .frame(maxWidth: .infinity)
                    .help("Its widgets move to the section above")
            }
        }
    }

    private var isShared: Binding<Bool> {
        Binding {
            section.isShared
        } set: {
            section.share = $0 ? 1 : nil
        }
    }

    private var shareBinding: Binding<Double> {
        Binding {
            section.share ?? 1
        } set: {
            section.share = $0
        }
    }
}

/// Every section drawn to scale in a small panel, its widgets as icons. The line between two shared sections drags
/// to move length from one to the other, keeping the sum of their weights.
private struct SectionsPreview: View {
    let selectedID: PanelSection.ID
    let position: PanelPosition
    let onSelect: (PanelSection.ID) -> Void
    @Environment(ConfigurationStore.self) private var store
    /// The two sections' lengths and weights when the current drag started.
    @State private var dragStart: (lengths: (CGFloat, CGFloat), weights: (Double, Double))?

    private static let icon: CGFloat = 14
    private static let padding: CGFloat = 4
    private static let gap: CGFloat = 8

    var body: some View {
        let sections = store.configuration.sections
        let isBar = position.isBar
        let length: CGFloat = isBar ? 300 : 230
        let lengths = SectionLayout.lengths(
            content: sections.map(contentLength), shares: sections.map(\.share), available: length,
            spacing: Self.gap)
        let stack = isBar ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        stack {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 {
                    divider(between: index - 1, and: index, in: sections, lengths: lengths)
                }
                block(section)
                    .frame(width: isBar ? lengths[index] : nil, height: isBar ? nil : lengths[index])
            }
        }
        .frame(width: isBar ? nil : 64, height: isBar ? 26 : nil)
        .padding(Self.padding)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
        .coordinateSpace(.named(Self.space))
        .frame(maxWidth: .infinity)
    }

    private static let space = "SectionsPreview"

    /// What the section's icons need, as `SectionLayout` treats a section's widgets.
    private func contentLength(_ section: PanelSection) -> CGFloat {
        let count = CGFloat(section.widgets.count)
        return count == 0 ? 0 : count * Self.icon + (count - 1) * 2 + 2 * Self.padding
    }

    private func block(_ section: PanelSection) -> some View {
        let isSelected = section.id == selectedID
        let isBar = position.isBar
        let icons = ForEach(section.widgets) { widget in
            widget.kind.metadata.iconTile(size: Self.icon)
        }
        return Group {
            if isBar {
                HStack(spacing: 2) { icons }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: section.alignment.horizontalAlignment)
            } else {
                VStack(spacing: 2) { icons }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: section.alignment.verticalAlignment)
            }
        }
        .padding(Self.padding)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect(section.id) }
        .help(store.configuration.title(of: section))
    }

    @ViewBuilder
    private func divider(
        between first: Int, and second: Int, in sections: [PanelSection], lengths: [CGFloat]
    ) -> some View {
        let isBar = position.isBar
        let isDraggable = sections[first].isShared && sections[second].isShared
        Capsule()
            .fill(isDraggable ? Color.primary.opacity(0.45) : .clear)
            .frame(width: isBar ? 2 : 22, height: isBar ? 14 : 2)
            .frame(width: isBar ? Self.gap : nil, height: isBar ? nil : Self.gap)
            .frame(maxWidth: isBar ? nil : .infinity, maxHeight: isBar ? .infinity : nil)
            .contentShape(Rectangle())
            .pointerStyle(isDraggable ? (isBar ? .columnResize : .rowResize) : nil)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        guard isDraggable else { return }
                        resize(sections[first], sections[second], lengths: (lengths[first], lengths[second]), by: value)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }

    private func resize(
        _ first: PanelSection, _ second: PanelSection, lengths: (CGFloat, CGFloat), by value: DragGesture.Value
    ) {
        let start = dragStart ?? (lengths, (first.share ?? 1, second.share ?? 1))
        dragStart = start
        let translation = position.isBar ? value.translation.width : value.translation.height
        let total = start.lengths.0 + start.lengths.1
        let firstLength = min(max(start.lengths.0 + translation, contentLength(first)), total - contentLength(second))
        guard total > 0 else { return }
        // Lengths of shared sections are proportional to their weights, so split the weights as the lengths.
        let weights = start.weights.0 + start.weights.1
        let firstWeight = max(0.1, (weights * Double(firstLength / total) * 10).rounded() / 10)
        let secondWeight = max(0.1, ((weights - firstWeight) * 10).rounded() / 10)
        store.configuration.updateSection(first.id) { $0.share = firstWeight }
        store.configuration.updateSection(second.id) { $0.share = secondWeight }
    }
}

private struct WidgetInspector: View {
    @Binding var widget: WidgetInstance
    let onRemove: () -> Void
    @Environment(WindowCoordinator.self) private var windows
    @State private var previewLayout = WidgetLayout.regular

    var body: some View {
        let metadata = widget.kind.metadata
        Section {
            Toggle(isOn: $widget.showsInSidePanel) { Label("Side panel", systemImage: "sidebar.left") }
            Toggle(isOn: $widget.showsInBar) { Label("Bar", systemImage: "menubar.rectangle") }
        } header: {
            // The preview sits in the header, straight on the inspector: in a section's card it would get a frame
            // around the stage, which already sets it apart.
            VStack(alignment: .leading, spacing: 0) {
                InspectorTitle(title: metadata.title, subtitle: metadata.summary) {
                    metadata.iconTile(size: 32)
                } accessories: {
                    if metadata.isBeta { BetaBadge() }
                    if let details = metadata.details { InfoButton(details) }
                }
                VStack(spacing: 10) {
                    WidgetInspectorPreview(settings: widget.settings, layout: previewLayout)
                    Picker("Size", selection: $previewLayout.animation(Motion.layout)) {
                        ForEach(WidgetLayout.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .padding(.bottom, 18)
                Text("Show in")
            }
        }

        if !widget.kind.styles.isEmpty {
            Section("Style") {
                StylePicker(settings: $widget.settings)
            }
        }

        Section("Settings") {
            builderRow
            WidgetSettingsEditor(settings: $widget.settings)
        }

        Section {
            Button("Remove from Panel", role: .destructive, action: onRemove)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var builderRow: some View {
        if widget.settings.hasBuilder {
            LabeledContent("Blocks") {
                Button("Open Builder", systemImage: "square.stack.3d.up") { windows.showBuilder(for: widget) }
            }
        }
    }
}

/// The selected widget at one size, on the dark stage previews sit on.
///
/// The settings sit below, so a stage that followed the card's height would move them under the pointer with every
/// change. It only grows, to the tallest the card has been at this size, and stops at ``maxHeight``, past which the
/// card fades out.
private struct WidgetInspectorPreview: View {
    let settings: WidgetSettings
    let layout: WidgetLayout
    /// The tallest the card has been at each size, while this widget is selected.
    @State private var tallest: [WidgetLayout: CGFloat] = [:]

    private static let padding: CGFloat = 12
    private static let maxHeight: CGFloat = 360

    var body: some View {
        let natural = tallest[layout].map { $0 + 2 * Self.padding }
        let height = layout.inspectorStageHeight ?? natural.map { min($0, Self.maxHeight) }
        let isCut = layout.inspectorStageHeight == nil && (natural ?? 0) > Self.maxHeight
        WidgetPreview(settings: settings, layout: layout)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: { cardHeight in
                tallest[layout] = max(tallest[layout] ?? 0, cardHeight)
            }
            .padding(Self.padding)
            .frame(maxWidth: .infinity)
            .frame(height: height, alignment: isCut ? .top : .center)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0.85), .init(color: .black.opacity(isCut ? 0 : 1), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom)
            }
            .background(PreviewStage())
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
