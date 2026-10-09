import AppKit
import ImageIO
import SidelightCore
import SwiftUI

/// The connected displays as arranged in System Settings, each with its panel drawn to scale. Click a display
/// to select it.
struct DisplayArrangementView: View {
    let displays: [Display]
    let configuration: AppConfiguration
    @Binding var selection: Display.ID?

    private let inset: CGFloat = 12
    /// Gap drawn between displays that touch.
    private let separation: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let bounds = displays.reduce(CGRect.null) { $0.union($1.frame) }
            let scale = scale(fitting: bounds, in: proxy.size)
            let origin = CGPoint(
                x: (proxy.size.width - bounds.width * scale) / 2,
                y: (proxy.size.height - bounds.height * scale) / 2
            )
            ZStack(alignment: .topLeading) {
                ForEach(displays) { display in
                    let frame = CGRect(
                        // Cocoa y grows upwards, SwiftUI's downwards.
                        x: origin.x + (display.frame.minX - bounds.minX) * scale,
                        y: origin.y + (bounds.maxY - display.frame.maxY) * scale,
                        width: display.frame.width * scale,
                        height: display.frame.height * scale
                    )
                    .insetBy(dx: separation / 2, dy: separation / 2)
                    DisplayThumbnail(
                        display: display,
                        configuration: configuration,
                        scale: scale,
                        isSelected: displays.count > 1 && display.id == selection
                    )
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .onTapGesture { withAnimation(Motion.snappy) { selection = display.id } }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func scale(fitting bounds: CGRect, in size: CGSize) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return 0 }
        return min((size.width - 2 * inset) / bounds.width, (size.height - 2 * inset) / bounds.height)
    }
}

/// One display: its wallpaper, menu bar, and the panel at its configured edge, width and length.
private struct DisplayThumbnail: View {
    let display: Display
    let configuration: AppConfiguration
    let scale: CGFloat
    let isSelected: Bool

    var body: some View {
        let panel = display.panel(in: configuration)
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        ZStack(alignment: .topLeading) {
            Wallpaper(display: display)
            Rectangle()
                .fill(.black.opacity(panel.showsPanel ? 0.1 : 0.45))
            menuBar
            if panel.showsPanel {
                panelMiniature(panel)
            } else {
                Label("No panel", systemImage: "eye.slash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            nameTag(avoiding: panel.showsPanel ? panel.position : nil)
        }
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                isSelected ? Color.accentColor : .white.opacity(0.18), lineWidth: isSelected ? 2.5 : 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .contentShape(shape)
        .animation(Motion.layout, value: panel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(display.name), \(panel.showsPanel ? "\(panel.position.title), \(panel.width.title), \(panel.length.title)" : "no panel")"
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The menu bar strip, as tall as the gap between the screen's top and its visible frame.
    private var menuBar: some View {
        Rectangle()
            .fill(.white.opacity(0.55))
            .frame(height: max(2, (display.frame.maxY - display.visibleFrame.maxY) * scale))
            .frame(maxWidth: .infinity)
    }

    private func panelMiniature(_ panel: DisplayPanel) -> some View {
        let frame = PanelMetrics.previewFrame(
            inStrip: PanelMetrics.frame(of: panel, on: display), position: panel.position, length: panel.length,
            alignment: panel.alignment)
        let columns = PanelMetrics.columns(of: panel, on: display)
        let rect = CGRect(
            x: (frame.minX - display.frame.minX) * scale,
            y: (display.frame.maxY - frame.maxY) * scale,
            width: max(5, frame.width * scale),
            height: max(5, frame.height * scale)
        )
        .insetBy(dx: 1, dy: 1)
        let shape = RoundedRectangle(cornerRadius: min(4, rect.width / 4), style: .continuous)
        return ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(Color.white.opacity(0.18))
            if !panel.position.isBar && rect.width > 14 {
                HStack(alignment: .top, spacing: 2) {
                    ForEach(0..<columns.count, id: \.self) { column in
                        MiniatureCards(
                            fill: .white.opacity(0.5),
                            heights: column.isMultiple(of: 2) ? [9, 14, 7, 11, 9] : [12, 8, 13, 9],
                            spacing: 2,
                            cornerRadius: 1.5
                        )
                    }
                }
                .padding(3)
            }
            shape.strokeBorder(Color.white.opacity(0.7), lineWidth: 0.75)
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }

    private func nameTag(avoiding position: PanelPosition?) -> some View {
        Text(display.name)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.45), in: Capsule())
            .foregroundStyle(.white)
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: nameTagAlignment(avoiding: position))
            .padding(.top, position == .bottom ? 4 : 0)
    }

    /// Out of the panel's way.
    private func nameTagAlignment(avoiding position: PanelPosition?) -> Alignment {
        switch position {
        case .left: .bottomTrailing
        case .right: .bottomLeading
        case .top, nil: .bottom
        case .bottom: .top
        }
    }
}
