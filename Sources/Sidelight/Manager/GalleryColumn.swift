import SidelightCore
import SwiftUI

/// Every widget kind, previewed live with real data at the chosen layout.
struct GalleryColumn: View {
    @Binding var previewLayout: WidgetLayout
    @Binding var selection: ManagerSelection?
    @Environment(ConfigurationStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                ColumnHeader(
                    title: "Gallery",
                    subtitle:
                        "Live previews with real data. Add with + (next to the selection) or drag a tile into your panel."
                )
                Spacer()
                Picker("Preview size", selection: $previewLayout.animation(Motion.layout)) {
                    ForEach(WidgetLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
            }
            .padding(.horizontal, 20)
            .padding(.top, 34)
            .padding(.bottom, 12)

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: previewLayout.galleryTileMinimumWidth), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(WidgetKind.allCases) { kind in
                        GalleryTile(kind: kind, previewLayout: previewLayout) { add(kind) }
                    }
                }
                .padding(20)
            }
        }
    }

    private func add(_ kind: WidgetKind) {
        let widget = WidgetInstance(kind: kind)
        withAnimation(Motion.layout) { store.configuration.addWidget(widget, near: selection) }
        selection = .widget(widget.id)
    }
}

private struct GalleryTile: View {
    let kind: WidgetKind
    let previewLayout: WidgetLayout
    let onAdd: () -> Void
    @Environment(ConfigurationStore.self) private var store
    @State private var isHovered = false

    private var instances: [WidgetInstance] { store.configuration.widgets.filter { $0.kind == kind } }

    var body: some View {
        let metadata = kind.metadata
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 0) {
            ZStack {
                PreviewStage()
                // Preview with the settings of the first instance in the panel, if there is one.
                WidgetPreview(settings: instances.first?.settings ?? .defaults(for: kind), layout: previewLayout)
                    .allowsHitTesting(false)
            }
            .frame(height: previewLayout.galleryStageHeight)
            .clipped()

            HStack(alignment: .center, spacing: 10) {
                metadata.iconTile(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(metadata.title).font(.system(size: 13, weight: .semibold))
                        if !instances.isEmpty {
                            Text(instances.count == 1 ? "Added" : "Added ×\(instances.count)")
                                .font(.system(size: 9.5, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(.green.opacity(0.18)))
                                .foregroundStyle(.green)
                        }
                    }
                    Text(metadata.summary).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                    if kind.styles.count > 1 {
                        Label("\(kind.styles.count) styles", systemImage: "swatchpalette")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 4)
                Button(action: onAdd) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold)).frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .clipShape(Circle())
                .help("Add \(metadata.title) to the panel")
                .accessibilityLabel("Add \(metadata.title)")
            }
            .padding(12)
        }
        .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(isHovered ? 0.18 : 0.08), lineWidth: 1))
        .shadow(color: .black.opacity(isHovered ? 0.22 : 0.08), radius: isHovered ? 14 : 5, y: isHovered ? 6 : 2)
        .scaleEffect(isHovered ? 1.015 : 1)
        .onHover { hovering in withAnimation(Motion.snappy) { isHovered = hovering } }
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
