import SidelightCore
import SwiftUI

/// The inspector's style control: the current style with arrows to step through the others while watching the
/// previews below, and a browser of them all. It stays this size however many styles a widget has.
struct StylePicker: View {
    @Binding var settings: WidgetSettings
    @State private var isBrowsing = false

    var body: some View {
        let styles = settings.kind.styles
        let index = styles.firstIndex { $0.id == settings.styleID } ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    isBrowsing = true
                } label: {
                    current(styles[index], position: index + 1, of: styles.count)
                }
                .buttonStyle(.plain)
                .help("Browse all styles")

                ControlGroup {
                    Button {
                        step(by: -1, in: styles, from: index)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("Previous style")
                    Button {
                        step(by: 1, in: styles, from: index)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .help("Next style")
                }
                .controlSize(.small)
                .fixedSize()
            }

            Button {
                isBrowsing = true
            } label: {
                Label("Browse \(styles.count) Styles", systemImage: "square.grid.2x2").frame(maxWidth: .infinity)
            }
        }
        .popover(isPresented: $isBrowsing, arrowEdge: .leading) {
            StyleBrowser(settings: $settings)
        }
    }

    private func current(_ style: WidgetStyle, position: Int, of count: Int) -> some View {
        HStack(spacing: 10) {
            StyleThumbnail(settings: settings)
            VStack(alignment: .leading, spacing: 2) {
                Text(style.title).font(.system(size: 13, weight: .semibold))
                Text(style.summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(style.family.title) · \(position) of \(count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// Wraps around at either end, like flipping through watch faces.
    private func step(by offset: Int, in styles: [WidgetStyle], from index: Int) {
        let next = styles[(index + offset + styles.count) % styles.count]
        withAnimation(Motion.snappy) { settings = settings.with(next) }
    }
}

/// The current style at the minimal size, frozen at the showcase time.
private struct StyleThumbnail: View {
    let settings: WidgetSettings

    var body: some View {
        PreviewStage()
            .frame(width: 52, height: 64)
            .overlay {
                WidgetPreview(settings: settings, layout: .minimal)
                    .scaleEffect(0.55)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .environment(\.frozenDate, WidgetPreview.showcaseDate)
    }
}

/// Every style of a widget as a grid of previews. Picking one applies it at once and keeps the browser open, so
/// the panel itself shows the choice while you keep looking. Large catalogs get search, family filters and
/// sections; small ones are just the grid.
private struct StyleBrowser: View {
    @Binding var settings: WidgetSettings
    @State private var query = ""
    /// `nil` shows every family.
    @State private var family: StyleFamily?
    @FocusState private var isSearchFocused: Bool

    /// From this many styles on, search, filters and sections help; below it they'd only add clutter.
    private static let largeCatalog = 7
    private static let width: CGFloat = 600
    private static let columnCount = 3
    private static let spacing: CGFloat = 14
    private static let tileHeight: CGFloat = StyleTile.stageHeight + 24

    var body: some View {
        let styles = settings.kind.styles
        let isLarge = styles.count >= Self.largeCatalog
        let families = StyleFamily.allCases.filter { family in styles.contains { $0.family == family } }
        let matches = styles.filter { (family == nil || $0.family == family) && $0.matches(query) }
        let isGrouped = isLarge && families.count > 1 && family == nil && query.isEmpty
        VStack(spacing: 0) {
            header(count: styles.count, isLarge: isLarge)
            if isLarge && families.count > 1 {
                filters(families)
            }
            Divider()
            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                grid(matches, families: isGrouped ? families : nil, showsFamily: !isGrouped && families.count > 1)
            }
        }
        .frame(width: Self.width, height: isLarge ? 580 : height(for: styles.count))
        .environment(\.frozenDate, WidgetPreview.showcaseDate)
        .onAppear { isSearchFocused = isLarge }
    }

    /// Small catalogs get a popover exactly as tall as their grid.
    private func height(for count: Int) -> CGFloat {
        let rows = CGFloat((count + Self.columnCount - 1) / Self.columnCount)
        return 52 + 2 * 16 + rows * Self.tileHeight + (rows - 1) * Self.spacing
    }

    private func header(count: Int, isLarge: Bool) -> some View {
        HStack(spacing: 8) {
            Text("\(settings.kind.metadata.title) Styles").font(.system(size: 15, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
            Spacer()
            if isLarge {
                searchField
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query, prompt: Text("Search styles"))
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onSubmit(pickFirstMatch)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(width: 210)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
    }

    private func filters(_ families: [StyleFamily]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                chip("All", isSelected: family == nil) { family = nil }
                ForEach(families) { candidate in
                    chip(candidate.title, isSelected: family == candidate) { family = candidate }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.never)
        .padding(.bottom, 10)
    }

    private func chip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(Motion.snappy, action)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07)))
                .foregroundStyle(isSelected ? .white : .primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// - Parameter families: Sections to group the styles into, or `nil` for one flat grid.
    private func grid(_ styles: [WidgetStyle], families: [StyleFamily]?, showsFamily: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: Self.columnCount),
                    spacing: Self.spacing,
                    pinnedViews: .sectionHeaders
                ) {
                    if let families {
                        ForEach(families) { family in
                            Section {
                                tiles(styles.filter { $0.family == family }, showsFamily: false)
                            } header: {
                                sectionHeader(family)
                            }
                        }
                    } else {
                        tiles(styles, showsFamily: showsFamily)
                    }
                }
                .padding(16)
            }
            .onAppear { proxy.scrollTo(settings.styleID, anchor: .center) }
        }
    }

    private func tiles(_ styles: [WidgetStyle], showsFamily: Bool) -> some View {
        ForEach(styles) { style in
            Button {
                withAnimation(Motion.snappy) { settings = settings.with(style) }
            } label: {
                StyleTile(
                    style: style, settings: settings.with(style), isSelected: style.id == settings.styleID,
                    showsFamily: showsFamily)
            }
            .buttonStyle(.plain)
            .id(style.id)
        }
    }

    private func sectionHeader(_ family: StyleFamily) -> some View {
        Text(family.title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .background(.bar)
    }

    private func pickFirstMatch() {
        let styles = settings.kind.styles.filter { (family == nil || $0.family == family) && $0.matches(query) }
        if let first = styles.first {
            withAnimation(Motion.snappy) { settings = settings.with(first) }
        }
    }
}

/// One style in the browser: its preview at the compact size, its name and, outside sections, its family.
private struct StyleTile: View {
    static let stageHeight: CGFloat = 118

    let style: WidgetStyle
    /// The widget's settings with this style picked.
    let settings: WidgetSettings
    let isSelected: Bool
    let showsFamily: Bool
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            PreviewStage()
                .frame(height: Self.stageHeight)
                .overlay {
                    WidgetPreview(settings: settings, layout: .compact)
                        .scaleEffect(0.78)
                        .allowsHitTesting(false)
                }
                .clipShape(shape)
                .overlay(
                    shape.strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(isHovered ? 0.3 : 0.08),
                        lineWidth: isSelected ? 2 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(6)
                    }
                }
            HStack(alignment: .firstTextBaseline) {
                Text(style.title).font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                Spacer(minLength: 4)
                if showsFamily {
                    Text(style.family.title).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 2)
            .frame(height: 18)
        }
        .contentShape(Rectangle())
        .scaleEffect(isHovered ? 1.02 : 1)
        .onHover { hovering in withAnimation(Motion.snappy) { isHovered = hovering } }
        .help(style.summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(style.title), \(style.summary)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
