import SidelightCore
import SwiftUI

/// Everything inside the panel window: background plus the visible widgets.
struct PanelRootView: View {
    let layout: PanelLayout
    /// Reports the content's natural length along the edge, margins included, whenever it changes.
    let onContentLengthChange: (CGFloat) -> Void
    @Environment(ConfigurationStore.self) private var store
    @Environment(DesktopPictures.self) private var desktopPictures
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        let appearance = store.configuration.appearance
        let isBar = layout.position.isBar
        let shape = RoundedRectangle(cornerRadius: isBar ? 14 : 22, style: .continuous)
        let margin = PanelMetrics.margin(isBar: isBar)
        let imageURL = appearance.background.image.url(desktopPictures: desktopPictures, displayID: layout.displayID)
        ZStack {
            PanelBackground(background: appearance.background, shape: shape, cutout: cutout(margin: margin))
            PanelWidgets(configuration: store.configuration, layout: layout) { length in
                onContentLengthChange(length + 2 * margin)
            }
            .clipShape(shape)
        }
        .padding(margin)
        .environment(\.colorScheme, appearance.colorScheme(system: systemColorScheme, imageURL: imageURL))
    }

    /// The desktop picture behind the background while the window fills its strip. A fitted window keeps its
    /// aligned end where the strip's is, so pinning the picture there lines it up at any length.
    private func cutout(margin: CGFloat) -> DesktopCutout {
        let alignment = layout.length == .fit ? layout.alignment : .center
        return DesktopCutout(
            displayID: layout.displayID,
            screen: layout.screenFrame,
            rect: layout.strip.insetBy(dx: margin, dy: margin),
            anchor: layout.position.isBar ? alignment.horizontalAlignment : alignment.verticalAlignment
        )
    }
}

/// The widgets in their sections, scrolling once they don't fit. Measures their natural length along the edge
/// inside the scroll view, so the measurement doesn't depend on the window's length.
private struct PanelWidgets: View {
    let configuration: AppConfiguration
    let layout: PanelLayout
    let onContentLengthChange: (CGFloat) -> Void

    var body: some View {
        let position = layout.position
        let sections = configuration.visibleSections(at: position, length: layout.length)
        let appearance = CardAppearance(configuration.appearance)
        if position.isBar {
            let padding: CGFloat = 4
            glassContainer {
                GeometryReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        stack(sections, axis: .horizontal, spacing: 6, available: proxy.size.width - 2 * padding) {
                            section in
                            HStack(spacing: 6) {
                                ForEach(section.widgets) { widget in
                                    WidgetCard(settings: widget.settings, layout: .bar, appearance: appearance)
                                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                                }
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: section.alignment.horizontalAlignment)
                        }
                        .padding(padding)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.width.rounded(.up)
                        } action: {
                            onContentLengthChange($0)
                        }
                        .animation(Motion.layout, value: sections.map(SectionLayoutKey.init))
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .defaultScrollAnchor(contentAnchor, for: .alignment)
                }
            }
        } else {
            let columns = layout.columns
            let layout = WidgetLayout(columns.density)
            let spacing: CGFloat = layout == .minimal ? 6 : 8
            let padding: CGFloat = layout == .minimal ? 5 : 10
            let firstIndices = sections.indices.map { sections[..<$0].reduce(0) { $0 + $1.widgets.count } }
            glassContainer {
                GeometryReader { proxy in
                    ScrollView(showsIndicators: false) {
                        stack(sections, axis: .vertical, spacing: spacing, available: proxy.size.height - 2 * padding) {
                            section in
                            let firstIndex = firstIndices[sections.firstIndex { $0.id == section.id } ?? 0]
                            MasonryLayout(columns: columns.count, spacing: spacing) {
                                ForEach(Array(section.widgets.enumerated()), id: \.element.id) { index, widget in
                                    WidgetCard(settings: widget.settings, layout: layout, appearance: appearance)
                                        .staggeredEntrance(index: firstIndex + index)
                                        .transition(
                                            .asymmetric(
                                                insertion: .scale(scale: 0.9, anchor: .top).combined(with: .opacity),
                                                removal: .opacity
                                            )
                                        )
                                }
                            }
                            .frame(maxHeight: .infinity, alignment: section.alignment.verticalAlignment)
                        }
                        .padding(padding)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height.rounded(.up)
                        } action: {
                            onContentLengthChange($0)
                        }
                        .animation(Motion.layout, value: sections.map(SectionLayoutKey.init))
                        .animation(Motion.layout, value: columns)
                    }
                    .defaultScrollAnchor(contentAnchor, for: .alignment)
                }
            }
        }
    }

    /// The sections along the edge. A filling panel shares out its visible length; a fitted one stacks them at
    /// their natural length, so the content length it reports never includes the window's own length.
    private func stack(
        _ sections: [PanelSection], axis: Axis, spacing: CGFloat, available: CGFloat,
        @ViewBuilder content: @escaping (PanelSection) -> some View
    ) -> some View {
        SectionStack(
            axis: axis,
            shares: sections.map(\.share),
            spacing: spacing,
            available: layout.length == .fill ? max(0, available) : 0
        ) {
            ForEach(sections) { content($0) }
        }
    }

    /// Where content shorter than the window sits, so it stays at the aligned end while the window resizes.
    private var contentAnchor: UnitPoint {
        let isBar = layout.position.isBar
        let alignment = layout.length == .fit ? layout.alignment : .start
        return switch alignment {
        case .start: isBar ? .leading : .top
        case .center: .center
        case .end: isBar ? .trailing : .bottom
        }
    }

    /// Separate glass cards share sampling (and morph together) inside one container.
    @ViewBuilder
    private func glassContainer(@ViewBuilder content: () -> some View) -> some View {
        if configuration.appearance.cards.style == .glass {
            GlassEffectContainer(spacing: 10, content: content)
        } else {
            content()
        }
    }
}

/// What moving, adding or resizing sections changes, so the panel animates exactly those changes.
private struct SectionLayoutKey: Hashable {
    let id: PanelSection.ID
    let share: Double?
    let alignment: PanelAlignment
    let widgets: [WidgetInstance.ID]

    init(_ section: PanelSection) {
        id = section.id
        share = section.share
        alignment = section.alignment
        widgets = section.widgets.map(\.id)
    }
}
