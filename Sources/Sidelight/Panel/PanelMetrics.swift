import AppKit
import SidelightCore

/// Panel geometry: how big it is and where it sits on a display.
enum PanelMetrics {
    /// Height of the top/bottom bar.
    static let barThickness: CGFloat = 44

    /// Space between the window's edges and the panel's rounded background.
    static func margin(isBar: Bool) -> CGFloat {
        isBar ? 4 : 6
    }

    /// The panel's extent perpendicular to its screen edge on `display`.
    static func thickness(of panel: DisplayPanel, on display: Display) -> CGFloat {
        panel.position.isBar ? barThickness : display.panelWidth(panel.width)
    }

    /// The strip along the edge the panel reserves on `display`, in Cocoa screen coordinates. Other windows keep
    /// out of all of it, even when the panel's window only fits its content.
    static func frame(of panel: DisplayPanel, on display: Display) -> CGRect {
        frame(position: panel.position, thickness: thickness(of: panel, on: display), in: display.visibleFrame)
    }

    /// Roughly where the panel's window goes inside `strip`, for previews that don't know its content: a fitted
    /// panel is drawn half as long as its strip.
    static func previewFrame(
        inStrip strip: CGRect, position: PanelPosition, length: PanelLength, alignment: PanelAlignment
    ) -> CGRect {
        let stripLength = position.isBar ? strip.width : strip.height
        return PanelGeometry.frame(
            inStrip: strip, position: position, length: length, alignment: alignment,
            contentLength: stripLength / 2, minimumLength: 0)
    }

    /// The panel's frame inside `visibleFrame`, in Cocoa screen coordinates.
    static func frame(position: PanelPosition, thickness: CGFloat, in visibleFrame: CGRect) -> CGRect {
        switch position {
        case .left:
            CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: thickness, height: visibleFrame.height)
        case .right:
            CGRect(
                x: visibleFrame.maxX - thickness, y: visibleFrame.minY, width: thickness, height: visibleFrame.height)
        case .top:
            CGRect(x: visibleFrame.minX, y: visibleFrame.maxY - thickness, width: visibleFrame.width, height: thickness)
        case .bottom:
            CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: visibleFrame.width, height: thickness)
        }
    }

    /// Everything a panel controller needs to place `panel` on `display`.
    static func placement(of panel: DisplayPanel, on display: Display) -> PanelPlacement {
        PanelPlacement(
            displayID: display.id,
            screenFrame: display.frame,
            strip: frame(of: panel, on: display),
            position: panel.position,
            length: panel.length,
            alignment: panel.alignment,
            columns: columns(of: panel, on: display)
        )
    }

    /// How a side panel on `display` lays out its widgets.
    static func columns(of panel: DisplayPanel, on display: Display) -> PanelColumns {
        PanelColumns(panelWidth: Double(display.panelWidth(panel.width)))
    }

    /// Where the panel starts its slide-in when it moves to `position`: slightly off its edge.
    static func entranceOffset(for position: PanelPosition) -> CGVector {
        switch position {
        case .left: CGVector(dx: -24, dy: 0)
        case .right: CGVector(dx: 24, dy: 0)
        case .top: CGVector(dx: 0, dy: 16)
        case .bottom: CGVector(dx: 0, dy: -16)
        }
    }
}

extension NSScreen {
    /// The screen with the menu bar, whose top-left corner is the origin of Accessibility coordinates.
    static var primary: NSScreen? { screens.first }
}
