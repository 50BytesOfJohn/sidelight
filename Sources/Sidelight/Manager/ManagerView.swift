import SidelightCore
import SwiftUI

/// The Widgets window: the panel's widgets on the left, a gallery of every widget in the middle,
/// and the selected widget's settings on the right. Every change applies to the live panel immediately.
struct ManagerView: View {
    @State private var previewLayout: WidgetLayout = .regular
    @State private var selection: ManagerSelection?

    var body: some View {
        HStack(spacing: 0) {
            ActiveWidgetsColumn(selection: $selection)
                .frame(width: 300)
            Divider()
            GalleryColumn(previewLayout: $previewLayout, selection: $selection)
                .frame(maxWidth: .infinity)
            Divider()
            InspectorColumn(selection: $selection)
                .frame(width: 350)
        }
        .background(.background)
    }
}

/// Column title with a one-line explanation.
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
