import SwiftUI
import UniformTypeIdentifiers

/// Preview sizes in the gallery: the three panel sizes plus the horizontal bar chip.
enum PreviewSize: String, CaseIterable, Identifiable {
    case regular, compact, minimal, bar
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var panelSize: PanelSize { switch self { case .regular: .regular; case .compact: .compact; case .minimal, .bar: .minimal } }
    var cardWidth: CGFloat? { switch self { case .regular: 296; case .compact: 178; case .minimal: 60; case .bar: nil } }
    var tileMin: CGFloat { switch self { case .regular: 330; case .compact: 230; case .minimal: 170; case .bar: 250 } }
    var stageHeight: CGFloat { switch self { case .regular: 250; case .compact: 170; case .minimal: 130; case .bar: 80 } }
}

struct ManagerView: View {
    @ObservedObject var store = ConfigStore.shared
    @State private var previewSize: PreviewSize = .regular
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            ActiveColumn(selection: $selection)
                .frame(width: 300)
            Divider()
            GalleryColumn(previewSize: $previewSize, selection: $selection)
                .frame(maxWidth: .infinity)
            Divider()
            InspectorColumn(selection: $selection)
                .frame(width: 350)
        }
        .background(.background)
    }
}

// MARK: - Left: active widgets (drag to reorder, drop gallery tiles to insert)

private struct ActiveColumn: View {
    @ObservedObject var store = ConfigStore.shared
    @Binding var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Your panel").font(.system(size: 20, weight: .bold))
                Text("Drag to reorder · drop gallery tiles here · changes apply live")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                PlacementSummary()
                    .padding(.top, 8)
            }
            .padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 10)

            List(selection: $selection) {
                ForEach($store.config.widgets) { $w in
                    ActiveRow(instance: $w, selected: selection == w.id)
                        .tag(w.id)
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            Button("Remove", role: .destructive) { remove(w.id) }
                            Button("Duplicate") { duplicate(w) }
                        }
                }
                .onMove { from, to in
                    withAnimation(Theme.layout) { store.config.widgets.move(fromOffsets: from, toOffset: to) }
                }
                .onDelete { idx in store.config.widgets.remove(atOffsets: idx) }
                .onInsert(of: [UTType.plainText]) { index, providers in
                    for p in providers {
                        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                            guard let kind = obj as? String, WidgetRegistry.descriptor(kind) != nil else { return }
                            DispatchQueue.main.async {
                                let inst = WidgetInstance(kind: kind)
                                withAnimation(Theme.layout) { store.config.widgets.insert(inst, at: min(index, store.config.widgets.count)) }
                                selection = inst.id
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            HStack {
                Text("\(store.config.widgets.count) widgets").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([store.url]) } label: { Label("config.json", systemImage: "doc.text") }
                    .buttonStyle(.borderless).font(.system(size: 11)).help("Reveal config.json (hand edits hot-reload)")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(VisualEffect(material: .sidebar, blending: .behindWindow).ignoresSafeArea())
    }

    func remove(_ id: UUID) {
        withAnimation(Theme.layout) { store.config.widgets.removeAll { $0.id == id } }
        if selection == id { selection = nil }
    }
    func duplicate(_ w: WidgetInstance) {
        var n = WidgetInstance(kind: w.kind, inSide: w.inSide, inBar: w.inBar); n.settings = w.settings
        if let i = store.config.widgets.firstIndex(where: { $0.id == w.id }) {
            withAnimation(Theme.layout) { store.config.widgets.insert(n, at: i + 1) }
            selection = n.id
        }
    }
}

/// Current position/size chips; quick switches live here too.
private struct PlacementSummary: View {
    @ObservedObject var store = ConfigStore.shared
    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(PanelPosition.allCases) { p in Button { store.config.position = p } label: { Label(p.title, systemImage: p.symbol) } }
            } label: { Label(store.config.position.title, systemImage: store.config.position.symbol) }
                .menuStyle(.button).buttonStyle(.bordered).controlSize(.small).fixedSize()
            Menu {
                ForEach(PanelSize.allCases) { s in Button(s.title) { store.config.size = s } }
            } label: { Text(store.config.position.isBar ? "Bar" : store.config.size.title) }
                .menuStyle(.button).buttonStyle(.bordered).controlSize(.small).fixedSize()
                .disabled(store.config.position.isBar)
            Spacer()
        }
    }
}

private struct ActiveRow: View {
    @Binding var instance: WidgetInstance
    let selected: Bool
    @State private var hover = false

    var body: some View {
        if let d = WidgetRegistry.descriptor(instance.kind) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                IconTile(meta: d.meta, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.meta.title).font(.system(size: 13, weight: .semibold))
                    Text(summary(d)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                PlacementChip(title: "Side", symbol: "sidebar.left", on: $instance.inSide)
                PlacementChip(title: "Bar", symbol: "menubar.rectangle", on: $instance.inBar)
            }
            .padding(.vertical, 5)
            .opacity(instance.inSide || instance.inBar ? 1 : 0.5)
            .onHover { hover = $0 }
        }
    }

    func summary(_ d: WidgetDescriptor) -> String {
        let s = instance.settings
        switch instance.kind {
        case "clock": return (s.use24h ? "24 h" : "12 h") + (s.showSeconds ? " · seconds" : "")
        case "codex": return s.showWeekly ? "5 h + weekly" : "5 h only"
        case "calendar": return "\(s.eventCount) event\(s.eventCount == 1 ? "" : "s")"
        case "system": return s.stats == .both ? "CPU + memory" : s.stats.rawValue.uppercased()
        default: return d.meta.summary
        }
    }
}

private struct PlacementChip: View {
    let title: String
    let symbol: String
    @Binding var on: Bool
    var body: some View {
        Button { withAnimation(Theme.snappy) { on.toggle() } } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 20)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.07)))
                .foregroundStyle(on ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .help(on ? "Shown in \(title.lowercased()) — click to hide" : "Hidden in \(title.lowercased()) — click to show")
    }
}

struct IconTile: View {
    let meta: WidgetMeta
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: meta.icon)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [meta.tint.opacity(0.95), meta.tint.opacity(0.65)], startPoint: .top, endPoint: .bottom)))
            .shadow(color: meta.tint.opacity(0.35), radius: 3, y: 1)
    }
}

// MARK: - Center: gallery with live previews

private struct GalleryColumn: View {
    @ObservedObject var store = ConfigStore.shared
    @Binding var previewSize: PreviewSize
    @Binding var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Gallery").font(.system(size: 20, weight: .bold))
                    Text("Live previews with real data. Add with + or drag a tile into your panel.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $previewSize.animation(Theme.layout)) {
                    ForEach(PreviewSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            }
            .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 12)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: previewSize.tileMin), spacing: 14)], spacing: 14) {
                    ForEach(WidgetRegistry.all) { d in
                        GalleryTile(desc: d, previewSize: previewSize) { add(d) }
                    }
                }
                .padding(20)
            }
        }
    }

    func add(_ d: WidgetDescriptor) {
        let inst = WidgetInstance(kind: d.meta.kind)
        withAnimation(Theme.layout) { store.config.widgets.append(inst) }
        selection = inst.id
    }
}

/// Dark gradient "desk" behind previews so glass/black chrome reads well.
struct PreviewStage: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.32), Color(red: 0.05, green: 0.07, blue: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.purple.opacity(0.35), .clear], center: .topTrailing, startRadius: 10, endRadius: 260)
        }
    }
}

private struct GalleryTile: View {
    @ObservedObject var store = ConfigStore.shared
    let desc: WidgetDescriptor
    let previewSize: PreviewSize
    let onAdd: () -> Void
    @State private var hover = false

    var count: Int { store.config.widgets.filter { $0.kind == desc.meta.kind }.count }
    var settings: WidgetSettings { store.config.widgets.first { $0.kind == desc.meta.kind }?.settings ?? WidgetSettings() }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                PreviewStage()
                WidgetPreview(kind: desc.meta.kind, settings: settings, size: previewSize)
                    .allowsHitTesting(false)
            }
            .frame(height: previewSize.stageHeight)
            .clipped()

            HStack(alignment: .center, spacing: 10) {
                IconTile(meta: desc.meta, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(desc.meta.title).font(.system(size: 13, weight: .semibold))
                        if count > 0 {
                            Text(count == 1 ? "Added" : "Added ×\(count)").font(.system(size: 9.5, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.green.opacity(0.18))).foregroundStyle(.green)
                        }
                    }
                    Text(desc.meta.summary).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Button(action: onAdd) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold)).frame(width: 28, height: 28)
                }
                .buttonStyle(.glass).clipShape(Circle())
                .help("Add \(desc.meta.title) to the panel")
            }
            .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(hover ? 0.18 : 0.08), lineWidth: 1))
        .shadow(color: .black.opacity(hover ? 0.22 : 0.08), radius: hover ? 14 : 5, y: hover ? 6 : 2)
        .scaleEffect(hover ? 1.015 : 1)
        .onHover { h in withAnimation(Theme.snappy) { hover = h } }
        .draggable(desc.meta.kind) {
            HStack { IconTile(meta: desc.meta, size: 24); Text(desc.meta.title).font(.system(size: 12, weight: .semibold)) }
                .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// A widget rendered with the panel's chrome at a given preview size.
struct WidgetPreview: View {
    @ObservedObject var store = ConfigStore.shared
    let kind: String
    let settings: WidgetSettings
    let size: PreviewSize

    var body: some View {
        var inst = WidgetInstance(kind: kind); inst.settings = settings
        let c = store.config
        // image mode previews use the black chrome (no image behind the preview)
        let chrome = Chrome(mode: c.mode == .image ? .black : c.mode, imageCards: c.imageCards, useGlass: c.useGlass)
        let ctx = WidgetContext(size: size.panelSize, bar: size == .bar, settings: settings)
        return Group {
            if size == .bar {
                WidgetCard(instance: inst, ctx: ctx, chrome: chrome).frame(height: 36).fixedSize(horizontal: true, vertical: false)
            } else {
                WidgetCard(instance: inst, ctx: ctx, chrome: chrome).frame(width: size.cardWidth).fixedSize(horizontal: false, vertical: true)
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(Theme.layout, value: size)
    }
}

// MARK: - Right: inspector for the selected instance

private struct InspectorColumn: View {
    @ObservedObject var store = ConfigStore.shared
    @Binding var selection: UUID?

    var index: Int? { store.config.widgets.firstIndex { $0.id == selection } }

    var body: some View {
        Group {
            if let i = index, let d = WidgetRegistry.descriptor(store.config.widgets[i].kind) {
                let binding = Binding<WidgetInstance>(
                    get: { store.config.widgets.indices.contains(i) ? store.config.widgets[i] : WidgetInstance(kind: d.meta.kind) },
                    set: { if store.config.widgets.indices.contains(i) { store.config.widgets[i] = $0 } })
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 12) {
                            IconTile(meta: d.meta, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.meta.title).font(.system(size: 18, weight: .bold))
                                Text(d.meta.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }

                        section("Show in") {
                            Toggle(isOn: binding.inSide) { Label("Side panel (left / right)", systemImage: "sidebar.left") }
                            Toggle(isOn: binding.inBar) { Label("Bar (top / bottom)", systemImage: "menubar.rectangle") }
                        }

                        section("Settings") {
                            d.settings(binding.settings)
                        }

                        section("Preview") {
                            VStack(alignment: .leading, spacing: 12) {
                                stage { WidgetPreview(kind: d.meta.kind, settings: binding.wrappedValue.settings, size: .regular) }
                                HStack(alignment: .top, spacing: 12) {
                                    stage { WidgetPreview(kind: d.meta.kind, settings: binding.wrappedValue.settings, size: .compact) }
                                    stage { WidgetPreview(kind: d.meta.kind, settings: binding.wrappedValue.settings, size: .minimal) }.frame(width: 84)
                                }
                                stage { WidgetPreview(kind: d.meta.kind, settings: binding.wrappedValue.settings, size: .bar) }.frame(height: 56)
                            }
                        }

                        Button(role: .destructive) {
                            let id = store.config.widgets[i].id
                            withAnimation(Theme.layout) { store.config.widgets.removeAll { $0.id == id } }
                            selection = nil
                        } label: { Label("Remove from panel", systemImage: "trash").frame(maxWidth: .infinity) }
                            .controlSize(.large)
                    }
                    .padding(18).padding(.top, 20)
                }
                .id(selection)
                .transition(.opacity.combined(with: .offset(x: 12)))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                    Text("Select a widget").font(.system(size: 14, weight: .semibold))
                    Text("Pick one in your panel to edit its settings and see it at every size.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 220)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(Theme.snappy, value: selection)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    func section<V: View>(_ title: String, @ViewBuilder _ v: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) { v() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
    }
    func stage<V: View>(@ViewBuilder _ v: () -> V) -> some View {
        ZStack { PreviewStage(); v().padding(8) }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
