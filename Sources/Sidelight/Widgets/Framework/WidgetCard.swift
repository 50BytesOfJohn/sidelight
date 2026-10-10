import AppKit
import SidelightCore
import SwiftUI

/// The parts of the configuration that decide how cards are drawn.
struct CardAppearance: Equatable {
    var cards: CardSettings
    /// Blur cards blur the panel's own color or image, otherwise what's behind the panel's window.
    var blendingMode: NSVisualEffectView.BlendingMode

    init(_ appearance: Appearance) {
        cards = appearance.cards
        let drawsOwnBackground = appearance.background.kind == .color || appearance.background.kind == .image
        blendingMode = drawsOwnBackground ? .withinWindow : .behindWindow
    }

    /// Previews sit on a stage in their own window, so blur cards blur the stage.
    var forPreview: CardAppearance {
        var appearance = self
        appearance.blendingMode = .withinWindow
        return appearance
    }
}

/// One widget rendered as a card (side panel) or a chip (bar), with the chrome for the panel style.
struct WidgetCard: View {
    let settings: WidgetSettings
    let layout: WidgetLayout
    let appearance: CardAppearance

    private var metadata: WidgetMetadata { settings.kind.metadata }

    var body: some View {
        switch layout {
        case .regular:
            VStack(alignment: .leading, spacing: 8) {
                header(fontSize: 10)
                WidgetContent(settings: settings, layout: layout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .cardChrome(appearance, cornerRadius: 16)
            .named(metadata.title, tooltip: !appearance.cards.showsTitles)
        case .compact:
            VStack(alignment: .leading, spacing: 6) {
                header(fontSize: 9)
                WidgetContent(settings: settings, layout: layout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .cardChrome(appearance, cornerRadius: 13)
            .named(metadata.title, tooltip: !appearance.cards.showsTitles)
        case .minimal:
            WidgetContent(settings: settings, layout: layout)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .padding(.horizontal, 4)
                .cardChrome(appearance, cornerRadius: 12)
                .named(metadata.title, tooltip: true)
        case .bar:
            WidgetContent(settings: settings, layout: layout)
                .padding(.horizontal, 9)
                .frame(maxHeight: .infinity)
                .cardChrome(appearance, cornerRadius: 11)
                .named(metadata.title, tooltip: true)
        }
    }

    /// The icon and name above the content, unless titles are hidden. A hidden title takes no space at all,
    /// including the stack's spacing below it.
    @ViewBuilder
    private func header(fontSize: CGFloat) -> some View {
        if appearance.cards.showsTitles {
            HStack(spacing: 5) {
                Image(systemName: metadata.systemImage)
                    .font(.system(size: fontSize, weight: .semibold))
                Text(metadata.title.uppercased())
                    .font(.system(size: fontSize, weight: .semibold))
                    .tracking(0.9)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            // The card's accessibility label already names the widget.
            .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Names the card's widget to VoiceOver as the label of the group holding its content, whether or not the
    /// title shows, and as a tooltip where it doesn't.
    fileprivate func named(_ title: String, tooltip: Bool) -> some View {
        help(tooltip ? title : "")
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
    }

    /// The card's background and border for the configured card style.
    func cardChrome(_ appearance: CardAppearance, cornerRadius: CGFloat) -> some View {
        modifier(CardChrome(appearance: appearance, cornerRadius: cornerRadius))
    }
}

private struct CardChrome: ViewModifier {
    let appearance: CardAppearance
    let cornerRadius: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        styled(content, shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .scaleEffect(isHovered ? 1.012 : 1)
            .onHover { hovering in
                withAnimation(Motion.snappy) { isHovered = hovering }
            }
    }

    @ViewBuilder
    private func styled(_ content: Content, shape: RoundedRectangle) -> some View {
        let cards = appearance.cards
        let border = shape.strokeBorder(Color.primary.opacity(isHovered ? 0.14 : 0.07), lineWidth: 0.5)
        switch cards.style {
        case .none:
            content.background(shape.fill(Color.primary.opacity(isHovered ? 0.05 : 0)))
        case .glass:
            content.glassEffect(.regular.tint(cards.tint.amount > 0 ? Color(cards.tint) : nil).interactive(), in: shape)
        case .blur:
            content
                .background(
                    ZStack {
                        VisualEffectBackground(.regular, blendingMode: appearance.blendingMode)
                        Color(cards.tint)
                    }
                    .clipShape(shape)
                )
                .overlay(border)
        case .solid:
            content
                .background(shape.fill(Color(cards.fill.color).opacity(cards.fill.amount + (isHovered ? 0.03 : 0))))
                .overlay(border)
        }
    }
}
