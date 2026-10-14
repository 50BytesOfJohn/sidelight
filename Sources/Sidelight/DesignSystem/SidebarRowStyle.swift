import AppKit
import SwiftUI

extension View {
    /// Draws a reorderable sidebar row's text in plain label colors rather than the sidebar's vibrant ones. Vibrant
    /// colors take their look from the material behind them, so the drag image the list draws of a row, with
    /// nothing behind it, came out black in dark mode. A selected row keeps the list's own contrasting style.
    func sidebarRowStyle() -> some View {
        modifier(SidebarRowStyle(primary: Color(nsColor: .labelColor), secondary: Color(nsColor: .secondaryLabelColor)))
    }

    /// The icon of a row drawn with ``sidebarRowStyle()``, in the accent color a sidebar gives its icons. Applied
    /// inside a `Label`'s icon, which the list styles apart from its title.
    func sidebarIconStyle() -> some View {
        modifier(SidebarRowStyle(primary: Color.accentColor, secondary: Color(nsColor: .secondaryLabelColor)))
    }
}

private struct SidebarRowStyle: ViewModifier {
    let primary: Color
    let secondary: Color
    /// Increased on a selected row, whose highlight the list draws behind it.
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        if prominence == .increased {
            content
        } else {
            content.foregroundStyle(primary, secondary)
        }
    }
}
