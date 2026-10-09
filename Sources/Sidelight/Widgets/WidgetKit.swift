import SwiftUI

// MARK: - Shared data models (one instance per app; widgets observe what they need)

final class AppModels {
    static let shared = AppModels()
    let cal = CalendarModel()
    let np = NowPlayingModel()
    let agents = AgentServer()
    let stats = StatsModel()
    let codex = CodexModel()
}

// MARK: - Widget protocol + registry

struct WidgetMeta {
    let kind: String
    let title: String
    let icon: String
    let tint: Color
    let summary: String
}

/// Everything a widget needs to render one instance at one size.
struct WidgetContext {
    var size: PanelSize
    /// horizontal top/bottom bar (always minimal); widgets lay out in a row instead of a column
    var bar: Bool = false
    var settings: WidgetSettings
    var models: AppModels = .shared
}

/// A widget = metadata + a view for a context (all three sizes + bar) + an inline settings editor.
protocol PanelWidget {
    static var meta: WidgetMeta { get }
    associatedtype Content: View
    associatedtype SettingsEditor: View
    @MainActor @ViewBuilder static func content(_ ctx: WidgetContext) -> Content
    @MainActor @ViewBuilder static func settings(_ s: Binding<WidgetSettings>) -> SettingsEditor
}

struct WidgetDescriptor: Identifiable {
    let meta: WidgetMeta
    let content: @MainActor (WidgetContext) -> AnyView
    let settings: @MainActor (Binding<WidgetSettings>) -> AnyView
    var id: String { meta.kind }
}

extension PanelWidget {
    static var descriptor: WidgetDescriptor {
        WidgetDescriptor(meta: meta, content: { AnyView(content($0)) }, settings: { AnyView(settings($0)) })
    }
}

enum WidgetRegistry {
    static let all: [WidgetDescriptor] = [
        ClockWidget.descriptor, CodexWidget.descriptor, CalendarWidget.descriptor, NowPlayingWidget.descriptor,
        AgentWidget.descriptor, SystemWidget.descriptor,
    ]
    static func descriptor(_ kind: String) -> WidgetDescriptor? { all.first { $0.meta.kind == kind } }
}

// MARK: - Card container (chrome + header per size)

struct Chrome {
    var mode: DisplayMode
    var imageCards: ImageCardStyle
    var useGlass: Bool
    static var current: Chrome { let c = ConfigStore.shared.config; return Chrome(mode: c.mode, imageCards: c.imageCards, useGlass: c.useGlass) }
}

struct CardChrome: ViewModifier {
    let chrome: Chrome
    let radius: CGFloat
    @State private var hover = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        styled(content, shape)
            .scaleEffect(hover ? 1.012 : 1)
            .onHover { h in withAnimation(Theme.snappy) { hover = h } }
    }

    @ViewBuilder private func styled(_ content: Content, _ shape: RoundedRectangle) -> some View {
        switch chrome.mode {
        case .black:
            content
                .background(shape.fill(Color(white: hover ? 0.115 : 0.085)))
                .overlay(shape.strokeBorder(Color.white.opacity(hover ? 0.13 : 0.07), lineWidth: 0.5))
        case .image:
            if chrome.imageCards == .glass && chrome.useGlass {
                content.glassEffect(.regular.tint(.black.opacity(0.15)), in: shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(hover ? 0.22 : 0.10), lineWidth: 0.5))
            } else {
                content.background(VisualEffect(material: .hudWindow, blending: .withinWindow).clipShape(shape))
                    .overlay(shape.strokeBorder(Color.white.opacity(hover ? 0.22 : 0.10), lineWidth: 0.5))
            }
        case .cards:
            if chrome.useGlass { content.glassEffect(.regular.interactive(), in: shape) }
            else { content.background(VisualEffect().clipShape(shape)) }
        case .glass:
            content
                .background(shape.fill(Color.primary.opacity(hover ? 0.085 : 0.05)))
                .overlay(shape.strokeBorder(Color.primary.opacity(hover ? 0.12 : 0.06), lineWidth: 0.5))
        }
    }
}

/// Renders one widget instance as a card (side panel) or a chip (bar).
struct WidgetCard: View {
    let instance: WidgetInstance
    let ctx: WidgetContext
    var chrome: Chrome = .current

    var body: some View {
        if let d = WidgetRegistry.descriptor(instance.kind) {
            let m = d.meta
            Group {
                if ctx.bar {
                    d.content(ctx)
                        .padding(.horizontal, 9)
                        .frame(maxHeight: .infinity)
                        .modifier(CardChrome(chrome: chrome, radius: 11))
                        .help(m.title)
                } else {
                    switch ctx.size {
                    case .regular:
                        VStack(alignment: .leading, spacing: 8) {
                            header(m, font: 10, iconSize: 10)
                            d.content(ctx)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .modifier(CardChrome(chrome: chrome, radius: 16))
                    case .compact:
                        VStack(alignment: .leading, spacing: 6) {
                            header(m, font: 9, iconSize: 9)
                            d.content(ctx)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .modifier(CardChrome(chrome: chrome, radius: 13))
                    case .minimal:
                        d.content(ctx)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9).padding(.horizontal, 4)
                            .modifier(CardChrome(chrome: chrome, radius: 12))
                            .help(m.title)
                    }
                }
            }
        }
    }

    func header(_ m: WidgetMeta, font: CGFloat, iconSize: CGFloat) -> some View {
        HStack(spacing: 5) {
            Image(systemName: m.icon).font(.system(size: iconSize, weight: .semibold))
            Text(m.title.uppercased()).font(.system(size: font, weight: .semibold)).tracking(0.9).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }
}

/// Staggered spring entrance — runs once on appear, then is static.
struct Entrance: ViewModifier {
    let index: Int
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 16)
            .scaleEffect(shown ? 1 : 0.97, anchor: .top)
            .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.05 + Double(index) * 0.06)) { shown = true } }
    }
}
