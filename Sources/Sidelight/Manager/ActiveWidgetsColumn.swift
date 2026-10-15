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
        List(selection: $selection) {
            ForEach(configuration.sections.rows) { row in
                switch row {
                case .section(let header):
                    sectionRow(header, in: configuration)
                case .widget(let widget):
                    let binding = binding(for: widget)
                    ActiveWidgetRow(widget: binding)
                        .tag(ManagerSelection.widget(widget.id))
                        .contextMenu {
                            Toggle("Show in Side Panel", isOn: binding.showsInSidePanel)
                            Toggle("Show in Bar", isOn: binding.showsInBar)
                            Divider()
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
            // Where the new section will appear, after the last one, rather than in a toolbar or at the window's
            // edge.
            NewSectionRow(action: addSection)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WindowSwitchLink(destination: .settings).padding(.horizontal, 10).padding(.bottom, 10)
        }
    }

    private func sectionRow(_ section: PanelSection, in configuration: AppConfiguration) -> some View {
        let index = configuration.sections.firstIndex { $0.id == section.id } ?? 0
        return SectionHeaderRow(
            title: configuration.title(of: section), summary: configuration.shortSummary(of: section)
        )
        .tag(ManagerSelection.section(section.id))
        .contextMenu {
            Button("Move Up") { moveSection(section.id, by: -1) }.disabled(index == 0)
            Button("Move Down") { moveSection(section.id, by: 1) }.disabled(index == configuration.sections.count - 1)
            Divider()
            Button("Remove Section", role: .destructive) { removeSection(section.id) }
                .disabled(configuration.sections.count == 1)
        }
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

    /// A copy uses the same accounts as the original: they belong to the app, not the widget.
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

/// A section's name, with its size and alignment after it, heading its widgets. A row like theirs, with a tile
/// like their icons, so it reads as something to select; no gap above it, which the list would highlight and
/// outline too.
private struct SectionHeaderRow: View {
    let title: String
    let summary: String

    var body: some View {
        HStack(spacing: 8) {
            IconTile(systemImage: "rectangle.split.1x2", tint: .gray, size: 18)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .help("Select to set the section's size and alignment. Drag to move it with its widgets.")
    }
}

/// Adds a section after the others.
private struct NewSectionRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { AddRowLabel(title: "New Section") }
            .buttonStyle(.plain)
            .help("Add a section below the others, with its own size and alignment")
            .padding(.top, 4)
    }
}

/// A widget in the panel. Its side panel and bar switches show while it's hovered; otherwise only a widget left out
/// of one of them says so. The inspector has the same switches for the selected widget.
private struct ActiveWidgetRow: View {
    @Binding var widget: WidgetInstance
    @State private var isHovered = false

    var body: some View {
        let metadata = widget.kind.metadata
        HStack(spacing: 10) {
            metadata.iconTile(size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(metadata.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(widget.settings.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if isHovered {
                HStack(spacing: 2) {
                    PlacementToggle(title: "Side panel", systemImage: "sidebar.left", isOn: $widget.showsInSidePanel)
                    PlacementToggle(title: "Bar", systemImage: "menubar.rectangle", isOn: $widget.showsInBar)
                }
                .transition(.opacity)
            } else if let note = placementNote {
                Image(systemName: note.systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .help(note.help)
            }
        }
        .padding(.vertical, 3)
        .opacity(widget.isHidden ? 0.55 : 1)
        .onHover { hovering in withAnimation(Motion.hover) { isHovered = hovering } }
    }

    /// Set when the widget is left out of the side panel, the bar or both.
    private var placementNote: (systemImage: String, help: String)? {
        switch (widget.showsInSidePanel, widget.showsInBar) {
        case (true, true): nil
        case (true, false): ("sidebar.left", "Only in the side panel")
        case (false, true): ("menubar.rectangle", "Only in the bar")
        case (false, false): ("eye.slash", "Hidden in the side panel and the bar")
        }
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
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                // Primary and tertiary, not the accent color, so they read on a selected row too.
                .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(
            isOn
                ? "Shown in the \(title.lowercased()). Click to hide."
                : "Hidden in the \(title.lowercased()). Click to show."
        )
        .accessibilityLabel("Show in \(title.lowercased())")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
