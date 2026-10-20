import SidelightCore
import SwiftUI

/// The outline of a panel's background, for its ``PanelShape``.
nonisolated struct PanelOutline: InsettableShape {
    var shape: PanelShape
    /// The screen edge a notch is joined to.
    var edge: PanelPosition
    var cornerRadius: CGFloat
    /// How far a notch's shoulders reach along its edge.
    var shoulder: CGFloat
    /// Leaves out the side along the screen edge, for a hairline around a notch.
    var isOpen = false
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .floating:
            return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).inset(by: inset).path(in: rect)
        case .notch:
            // A notch stays flush with its edge however it's inset.
            var insets = EdgeInsets(top: inset, leading: inset, bottom: inset, trailing: inset)
            switch edge {
            case .top: insets.top = 0
            case .bottom: insets.bottom = 0
            case .left: insets.leading = 0
            case .right: insets.trailing = 0
            }
            let rect = CGRect(
                x: rect.minX + insets.leading, y: rect.minY + insets.top,
                width: max(0, rect.width - insets.leading - insets.trailing),
                height: max(0, rect.height - insets.top - insets.bottom))
            return Path(
                NotchOutline.path(
                    in: rect, edge: edge, cornerRadius: max(0, cornerRadius - inset), shoulder: shoulder,
                    isClosed: !isOpen))
        }
    }

    func inset(by amount: CGFloat) -> PanelOutline {
        var outline = self
        outline.inset += amount
        return outline
    }

    /// The same outline without the side along the screen edge, so a hairline traces only the sides that stand out.
    var open: PanelOutline {
        var outline = self
        outline.isOpen = true
        return outline
    }
}

/// How a panel's background sits in its window: its outline, the space around it, and the space inside it the
/// widgets keep clear of.
struct PanelChrome {
    let outline: PanelOutline
    /// Between the window's edges and the background.
    let margins: EdgeInsets
    /// Between the background's edges and the widgets, keeping them off a notch's shoulders.
    let padding: EdgeInsets

    /// For a panel of `shape` along `edge`: a bar along the top or bottom, or a side panel.
    init(_ shape: PanelShape, edge: PanelPosition) {
        let isBar = edge.isBar
        let margin = PanelMetrics.margin(isBar: isBar)
        let shoulder: CGFloat = isBar ? 10 : 14
        outline = PanelOutline(shape: shape, edge: edge, cornerRadius: isBar ? 14 : 22, shoulder: shoulder)
        switch shape {
        case .floating:
            margins = EdgeInsets(top: margin, leading: margin, bottom: margin, trailing: margin)
            padding = EdgeInsets()
        case .notch:
            // Flush with the edge, apart from the windows on the other side, and the full length of the window.
            margins =
                switch edge {
                case .top: EdgeInsets(top: 0, leading: 0, bottom: margin, trailing: 0)
                case .bottom: EdgeInsets(top: margin, leading: 0, bottom: 0, trailing: 0)
                case .left: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: margin)
                case .right: EdgeInsets(top: 0, leading: margin, bottom: 0, trailing: 0)
                }
            padding =
                isBar
                ? EdgeInsets(top: 0, leading: shoulder, bottom: 0, trailing: shoulder)
                : EdgeInsets(top: shoulder, leading: 0, bottom: shoulder, trailing: 0)
        }
    }

    /// Everything around the widgets along the edge, margins and padding at both ends.
    var lengthAroundContent: CGFloat {
        outline.edge.isBar
            ? margins.leading + margins.trailing + padding.leading + padding.trailing
            : margins.top + margins.bottom + padding.top + padding.bottom
    }

    /// What the background covers of `rect`, a window's frame in Cocoa screen coordinates, where y grows upwards.
    func background(in rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + margins.leading, y: rect.minY + margins.bottom,
            width: rect.width - margins.leading - margins.trailing,
            height: rect.height - margins.top - margins.bottom)
    }
}
