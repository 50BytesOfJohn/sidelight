import AppKit
import SidelightCore
import SwiftUI
import UniformTypeIdentifiers

/// The panel's sections and their widgets in one list: drag widgets to reorder them or move them to another
/// section, drop gallery tiles to insert.
///
/// Every row is in a single `ForEach`, headers included, so one `onMove` works across sections; the sections are
/// rebuilt from the new row order afterwards. Dragging a header moves its whole section.
struct ActiveWidgetsColumn: View {
    @Binding var selection: ManagerSelection?
    @Environment(ConfigurationStore.self) private var store

    var body: some View {
        let configuration = store.configuration
        let widgetCount = configuration.widgets.count
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                ColumnHeader(
                    title: "Your panel",
                    subtitle: "Drag widgets between sections · drop gallery tiles here · changes apply live")
                PlacementSummary().padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 34)
            .padding(.bottom, 10)

            List(selection: $selection) {
                ForEach(configuration.sections.rows) { row in
                    switch row {
                    case .section(let header):
                        sectionRow(header, in: configuration)
                    case .widget(let widget):
                        ActiveWidgetRow(widget: binding(for: widget))
                            .tag(ManagerSelection.widget(widget.id))
                            .listRowSeparator(.hidden)
                            .contextMenu {
                                Button("Duplicate") { duplicate(widget) }
                                Button("Remove", role: .destructive) { remove(widget.id) }
                            }
                    }
                }
                .onMove { source, destination in
                    withAnimation(Motion.layout) {
                        store.configuration.moveRows(fromOffsets: source, toOffset: destination)
                    }
                }
                .onDelete { offsets in
                    let rows = store.configuration.sections.rows
                    for offset in offsets {
                        if case .widget(let widget) = rows[offset] { remove(widget.id) }
                    }
                }
                .onInsert(of: [.plainText]) { index, providers in
                    for provider in providers {
                        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                            guard let rawValue = object as? String, let kind = WidgetKind(rawValue: rawValue) else {
                                return
                            }
                            Task { @MainActor in insert(kind, atRow: index) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            HStack {
                Text(widgetCount == 1 ? "1 widget" : "\(widgetCount) widgets")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: addSection) {
                    Label("Add Section", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .help("Add a section below the others, with its own size and alignment")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                } label: {
                    Label("config.json", systemImage: "doc.text")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .help("Reveal config.json in Finder (hand edits are applied live)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().padding(.horizontal, 16)
            WindowSwitchLink(destination: .settings).padding(10)
        }
        .background(VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow).ignoresSafeArea())
    }

    private func sectionRow(_ section: PanelSection, in configuration: AppConfiguration) -> some View {
        let index = configuration.sections.firstIndex { $0.id == section.id } ?? 0
        let isEmpty = configuration.section(section.id)?.widgets.isEmpty ?? true
        return SectionHeaderRow(
            title: configuration.title(of: section),
            summary: isEmpty
                ? "Empty · drag widgets here"
                : "\(configuration.sizeSummary(of: section)) · \(alignmentSummary(section, in: configuration))"
        )
        .tag(ManagerSelection.section(section.id))
        .listRowSeparator(.hidden)
        .contextMenu {
            Button("Move Up") { moveSection(section.id, by: -1) }.disabled(index == 0)
            Button("Move Down") { moveSection(section.id, by: 1) }.disabled(index == configuration.sections.count - 1)
            Divider()
            Button("Remove Section", role: .destructive) { removeSection(section.id) }
                .disabled(configuration.sections.count == 1)
        }
    }

    private func alignmentSummary(_ section: PanelSection, in configuration: AppConfiguration) -> String {
        "aligned \(section.alignment.title(for: configuration.panel.position).lowercased())"
    }

    /// Looks the widget up by identity on every access, so edits never land on the wrong one after a move.
    private func binding(for widget: WidgetInstance) -> Binding<WidgetInstance> {
        Binding {
            store.configuration.widget(widget.id) ?? widget
        } set: { updated in
            store.configuration.updateWidget(widget.id) { $0 = updated }
        }
    }

    private func insert(_ kind: WidgetKind, atRow index: Int) {
        let widget = WidgetInstance(kind: kind)
        withAnimation(Motion.layout) { store.configuration.insertWidgets([widget], atRow: index) }
        selection = .widget(widget.id)
    }

    private func remove(_ id: WidgetInstance.ID) {
        withAnimation(Motion.layout) { store.configuration.removeWidget(id) }
        if selection == .widget(id) { selection = nil }
    }

    private func duplicate(_ widget: WidgetInstance) {
        let copy = widget.duplicated()
        withAnimation(Motion.layout) { store.configuration.insertWidget(copy, after: widget.id) }
        selection = .widget(copy.id)
    }

    private func addSection() {
        var section: PanelSection?
        withAnimation(Motion.layout) { section = store.configuration.addSection() }
        if let section { selection = .section(section.id) }
    }

    private func removeSection(_ id: PanelSection.ID) {
        withAnimation(Motion.layout) { store.configuration.removeSection(id) }
        if selection == .section(id) { selection = nil }
    }

    private func moveSection(_ id: PanelSection.ID, by offset: Int) {
        withAnimation(Motion.layout) { store.configuration.moveSection(id, by: offset) }
    }
}

/// The default position, with a quick switch. Sizes and per-display settings live in Settings.
private struct PlacementSummary: View {
    @Environment(ConfigurationStore.self) private var store

    var body: some View {
        let configuration = store.configuration
        HStack(spacing: 6) {
            Menu {
                ForEach(PanelPosition.allCases) { position in
                    Button {
                        store.configuration.panel.position = position
                    } label: {
                        Label(position.title, systemImage: position.systemImage)
                    }
                }
            } label: {
                Label(configuration.panel.position.title, systemImage: configuration.panel.position.systemImage)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()

            Spacer()
        }
    }
}

/// A section's header: its name, how long it is and where its widgets sit.
private struct SectionHeaderRow: View {
    let title: String
    let summary: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.split.1x2")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(summary).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
        .help("Select to change the section's size and alignment; drag to move it with its widgets")
    }
}

private struct ActiveWidgetRow: View {
    @Binding var widget: WidgetInstance

    var body: some View {
        let metadata = widget.kind.metadata
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            metadata.iconTile(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(metadata.title).font(.system(size: 13, weight: .semibold))
                Text(widget.settings.summary).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            PlacementToggle(title: "Side", systemImage: "sidebar.left", isOn: $widget.showsInSidePanel)
            PlacementToggle(title: "Bar", systemImage: "menubar.rectangle", isOn: $widget.showsInBar)
        }
        .padding(.vertical, 5)
        .opacity(widget.isHidden ? 0.5 : 1)
    }
}

private struct PlacementToggle: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(Motion.snappy) { isOn.toggle() }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.07))
                )
                .foregroundStyle(isOn ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .help(
            isOn
                ? "Shown in the \(title.lowercased()) — click to hide"
                : "Hidden in the \(title.lowercased()) — click to show"
        )
        .accessibilityLabel("Show in \(title.lowercased())")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
