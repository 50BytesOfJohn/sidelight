import SidelightCore
import SwiftUI

/// Every widget kind, previewed live with real data at the chosen layout, grouped by category.
struct GalleryColumn: View {
    /// `nil` shows every category, each under its own heading.
    let category: WidgetCategory?
    /// Words every shown kind matches, in its name, summary, details or category. Empty shows them all.
    let search: String
    let previewLayout: WidgetLayout
    @Binding var selection: ManagerSelection?
    @Environment(ConfigurationStore.self) private var store

    var body: some View {
        let configuration = store.configuration
        // Read once here and handed down, so editing the configuration redraws only the tiles it changes.
        let appearance = CardAppearance(configuration.appearance).forPreview
        let instances = Dictionary(grouping: configuration.widgets, by: \.kind)
        let tile = { (kind: WidgetKind) in
            GalleryTile(
                kind: kind, layout: previewLayout, appearance: appearance, placed: instances[kind] ?? []
            ) {
                add(kind)
            }
            .equatable()
        }
        let categories = (category.map { [$0] } ?? WidgetCategory.allCases)
            .map { ($0, $0.kinds.filter { $0.matches(search) }) }
            .filter { !$0.1.isEmpty }
        if categories.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            grid(categories, tile: tile)
        }
    }

    private func grid<Tile: View>(
        _ categories: [(WidgetCategory, [WidgetKind])], tile: @escaping (WidgetKind) -> Tile
    ) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: previewLayout.galleryTileMinimumWidth), spacing: 16)],
                alignment: .leading,
                spacing: 16
            ) {
                // One category needs no heading: the toolbar names it.
                if category != nil, let (_, kinds) = categories.first {
                    ForEach(kinds, content: tile)
                } else {
                    ForEach(categories, id: \.0) { category, kinds in
                        Section {
                            ForEach(kinds, content: tile)
                        } header: {
                            Text(category.title)
                                .font(.title3.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, category == categories.first?.0 ? 0 : 12)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func add(_ kind: WidgetKind) {
        let widget = WidgetInstance(kind: kind)
        withAnimation(Motion.layout) { store.configuration.addWidget(widget, near: selection) }
        selection = .widget(widget.id)
    }
}

extension WidgetCategory {
    var kinds: [WidgetKind] { WidgetKind.allCases.filter { $0.category == self } }
}

extension WidgetKind {
    /// Whether every word of `search` is in the kind's name, summary, details or category, ignoring case and
    /// accents: "claude limits" finds Claude Code and AI Usage.
    func matches(_ search: String) -> Bool {
        let metadata = self.metadata
        let text = [metadata.title, metadata.summary, metadata.details ?? "", category.title].joined(separator: " ")
        return search.split(whereSeparator: \.isWhitespace).allSatisfy {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

/// One widget kind: its live preview, name and summary, and a button to add it. Drag it into the sidebar to add it
/// at a particular place.
private struct GalleryTile: View, Equatable {
    let kind: WidgetKind
    let layout: WidgetLayout
    let appearance: CardAppearance
    /// The panel's widgets of this kind. The preview uses the first one's settings.
    let placed: [WidgetInstance]
    let onAdd: () -> Void
    @State private var isHovered = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.layout == rhs.layout && lhs.appearance == rhs.appearance
            && lhs.placed.first?.settings == rhs.placed.first?.settings && lhs.placed.count == rhs.placed.count
    }

    var body: some View {
        let metadata = kind.metadata
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 0) {
            PreviewStage()
                .overlay {
                    CenteredUnlessTaller(margin: 16) {
                        WidgetPreview(
                            settings: placed.first?.settings ?? .defaults(for: kind), layout: layout,
                            appearance: appearance
                        )
                    }
                    .allowsHitTesting(false)
                }
                .frame(height: layout.galleryStageHeight)
                .clipped()

            HStack(spacing: 10) {
                metadata.iconTile(size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(metadata.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if metadata.isBeta { BetaBadge() }
                        if !placed.isEmpty {
                            TagBadge(title: placed.count == 1 ? "Added" : "Added ×\(placed.count)", tint: .green)
                        }
                    }
                    Text(metadata.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("Add \(metadata.title)", systemImage: "plus", action: onAdd)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Add to your panel, after the selected widget")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(isHovered ? 0.2 : 0.08), lineWidth: 1))
        .onHover { hovering in withAnimation(Motion.hover) { isHovered = hovering } }
        .help(metadata.details ?? metadata.summary)
        .draggable(kind.rawValue) {
            HStack {
                metadata.iconTile(size: 24)
                Text(metadata.title).font(.system(size: 12, weight: .semibold))
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Centers its one view, or, when the view is taller than the space, pins it `margin` from the top so a tall widget
/// shows its head rather than its middle.
private struct CenteredUnlessTaller: Layout {
    let margin: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let y = size.height + 2 * margin > bounds.height ? bounds.minY + margin : bounds.midY - size.height / 2
        view.place(at: CGPoint(x: bounds.midX, y: y), anchor: .top, proposal: ProposedViewSize(size))
    }
}
