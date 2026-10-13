import SidelightCore
import SwiftUI

/// The Widgets window: the panel's widgets in the sidebar, a gallery of every widget, and the selected widget's or
/// section's settings in the inspector. Every change applies to the live panel immediately.
struct ManagerView: View {
    @State private var selection: ManagerSelection?
    /// `nil` shows every category.
    @State private var category: WidgetCategory?
    @State private var search = ""
    @State private var isInspectorShown = true
    @AppStorage("GalleryPreviewLayout") private var previewLayout = WidgetLayout.regular
    @Environment(WindowCoordinator.self) private var windows

    var body: some View {
        NavigationSplitView {
            ActiveWidgetsColumn(selection: $selection)
                .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 360)
        } detail: {
            GalleryColumn(category: category, search: search, previewLayout: previewLayout, selection: $selection)
                .toolbar { toolbar }
                .inspector(isPresented: $isInspectorShown) {
                    InspectorColumn(selection: $selection)
                        .inspectorColumnWidth(min: 320, ideal: 360, max: 480)
                }
        }
        .onChange(of: selection) {
            if selection != nil { isInspectorShown = true }
        }
        // Clocks in the previews stop while the window is covered, minimized or on another Space.
        .environment(\.isPanelShown, windows.isManagerVisible)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Category", selection: $category) {
                Text("All").tag(WidgetCategory?.none)
                ForEach(WidgetCategory.allCases) { Text($0.title).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        // Its own field, next to the categories it narrows down further: `searchable` puts one over the inspector,
        // where it would seem to search settings.
        ToolbarItem(placement: .principal) {
            GallerySearchField(text: $search)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // One icon, like the inspector's button beside it: a toolbar drops a menu's text, and its chevron alone
            // sits off-center. The menu ticks the size shown.
            Menu {
                Picker("Preview Size", selection: $previewLayout.animation(Motion.layout)) {
                    ForEach(WidgetLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label("Preview Size", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .menuIndicator(.hidden)
            .help("Preview size: \(previewLayout.title)")
            Button {
                isInspectorShown.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(isInspectorShown ? "Hide the inspector" : "Show the inspector")
        }
    }
}

/// Narrows the gallery to the widgets whose words match. ⌘F focuses it and Escape clears it.
private struct GallerySearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onExitCommand {
                    text = ""
                    isFocused = false
                }
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 180)
        .background {
            Button("Search Widgets") { isFocused = true }
                .keyboardShortcut("f")
                .hidden()
        }
    }
}

/// Column title with a one-line explanation, as the builder heads its columns.
struct ColumnHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 20, weight: .bold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

extension WidgetMetadata {
    func iconTile(size: CGFloat) -> IconTile {
        IconTile(systemImage: systemImage, tint: tint, size: size, logo: logo)
    }
}

/// What the inspector edits: a widget or a section.
enum ManagerSelection: Hashable {
    case widget(WidgetInstance.ID)
    case section(PanelSection.ID)
}

extension AppConfiguration {
    /// Adds `widget` next to the selection: after the selected widget, at the end of the selected section, or at
    /// the end of the last section.
    mutating func addWidget(_ widget: WidgetInstance, near selection: ManagerSelection?) {
        switch selection {
        case .widget(let id): insertWidget(widget, after: id)
        case .section(let id): appendWidget(widget, toSection: id)
        case nil: appendWidget(widget)
        }
    }

    /// The section's name, or "Section 2" and so on by its place in the panel.
    func title(of section: PanelSection) -> String {
        if let name = section.name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        let number = (sections.firstIndex { $0.id == section.id } ?? sections.count) + 1
        return "Section \(number)"
    }

    /// e.g. "Half of the free space", "Fits its widgets".
    func sizeSummary(of section: PanelSection) -> String {
        guard let fraction = freeLengthFraction(of: section.id) else { return "Fits its widgets" }
        return "\(FreeLengthFraction.title(fraction)) of the free space"
    }

    /// e.g. "Half · top", "Fits widgets · centered", "Empty", for the sidebar's section rows.
    func shortSummary(of section: PanelSection) -> String {
        guard let widgets = self.section(section.id)?.widgets, !widgets.isEmpty else { return "Empty" }
        let size = freeLengthFraction(of: section.id).map(FreeLengthFraction.title) ?? "Fits widgets"
        return "\(size) · \(section.alignment.title(for: panel.position).lowercased())"
    }
}

/// Names for the part of the free length a section gets.
enum FreeLengthFraction {
    private static let named: [(Double, String)] = [
        (1, "All"), (1 / 2, "Half"), (1 / 3, "A third"), (2 / 3, "Two thirds"), (1 / 4, "A quarter"),
        (3 / 4, "Three quarters"), (1 / 5, "A fifth"), (2 / 5, "Two fifths"), (3 / 5, "Three fifths"),
        (4 / 5, "Four fifths"),
    ]

    /// "Half", "A third", or a percentage such as "43 %" for the rest.
    static func title(_ fraction: Double) -> String {
        if let (_, name) = named.first(where: { abs($0.0 - fraction) < 0.001 }) { return name }
        return "\(Int((fraction * 100).rounded())) %"
    }
}
