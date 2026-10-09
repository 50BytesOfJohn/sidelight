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
        .animation(Motion.snappy, value: selection)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    private func inspector(id: UUID, @ViewBuilder content: () -> some View) -> some View {
        ScrollView {
            content()
                .padding(18)
                .padding(.top, 20)
        }
        .id(id)
        .transition(.opacity.combined(with: .offset(x: 12)))
    }

    private var placeholder: some View {
        ContentUnavailableView {
            Label("Select a widget or section", systemImage: "square.grid.2x2")
        } description: {
            Text("Pick a widget to edit its settings and see it at every size, or a section to set its size.")
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.split.1x2")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(configuration.title(of: section)).font(.system(size: 18, weight: .bold))
                    Text(section.widgets.count == 1 ? "1 widget" : "\(section.widgets.count) widgets")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            InspectorSection("Panel") {
                SectionsPreview(selectedID: section.id, position: position, onSelect: onSelect)
                Text("Drag the line between two shared sections to resize them; click a section to select it.")
                    .inspectorFootnote()
            }

            InspectorSection("Name") {
                TextField(
                    configuration.title(of: PanelSection(id: section.id)),
                    text: Binding {
                        section.name ?? ""
                    } set: {
                        section.name = $0.isEmpty ? nil : $0
                    }
                )
                .textFieldStyle(.roundedBorder)
                Text("Only shown here, to tell sections apart.").inspectorFootnote()
            }

            InspectorSection("Size") {
                Picker("Size", selection: isShared.animation(Motion.layout)) {
                    Text("Fit widgets").tag(false)
                    Text("Share of free space").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if let share = section.share, section.isShared {
                    Stepper(value: shareBinding.animation(Motion.layout), in: 0.1...10, step: 0.5) {
                        let summary = Text(configuration.sizeSummary(of: section)).foregroundStyle(.secondary)
                        Text("Weight \(share.formatted(.number.precision(.fractionLength(0...1)))) · \(summary)")
                    }
                    Text("Shared sections split what fitting sections leave, by weight: 1 and 1 make halves.")
                        .inspectorFootnote()
                } else {
                    Text("As long as its widgets, however long the panel is.").inspectorFootnote()
                }
            }

            InspectorSection("Alignment") {
                Picker("Alignment", selection: $section.alignment.animation(Motion.layout)) {
                    ForEach(PanelAlignment.allCases) { alignment in
                        Text(alignment.title(for: position)).tag(alignment)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Where the widgets sit when the section is longer than they are.").inspectorFootnote()
            }

            if !fittedPanels.isEmpty {
                Label(
                    "Where the panel fits its content, sections stack at their natural length, so size and "
                        + "alignment apply only where it fills its edge.",
                    systemImage: "info.circle"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove Section", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
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

extension Text {
    fileprivate func inspectorFootnote() -> some View {
        font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct WidgetInspector: View {
    @Binding var widget: WidgetInstance
    let onRemove: () -> Void

    var body: some View {
        let metadata = widget.kind.metadata
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                metadata.iconTile(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(metadata.title).font(.system(size: 18, weight: .bold))
                    Text(metadata.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            InspectorSection("Show in") {
                Toggle(isOn: $widget.showsInSidePanel) {
                    Label("Side panel (left / right)", systemImage: "sidebar.left")
                }
                Toggle(isOn: $widget.showsInBar) { Label("Bar (top / bottom)", systemImage: "menubar.rectangle") }
            }

            if !widget.kind.styles.isEmpty {
                InspectorSection("Style") {
                    StylePicker(settings: $widget.settings)
                }
            }

            InspectorSection("Settings") {
                WidgetSettingsEditor(settings: $widget.settings)
            }

            InspectorSection("Preview") {
                VStack(alignment: .leading, spacing: 12) {
                    stage(.regular)
                    HStack(alignment: .top, spacing: 12) {
                        stage(.compact)
                        stage(.minimal).frame(width: 84)
                    }
                    stage(.bar).frame(height: 56)
                }
            }

            Button(role: .destructive, action: onRemove) {
                Label("Remove from Panel", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    private func stage(_ layout: WidgetLayout) -> some View {
        ZStack {
            PreviewStage()
            WidgetPreview(settings: widget.settings, layout: layout).padding(8)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
    }
}
