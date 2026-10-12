import SwiftUI

extension View {
    /// A soft highlight behind a clickable row while the pointer is over it, reaching 5 points beyond the row's
    /// sides and `vertical` points above and below, so its text doesn't touch the edge. With `isEnabled` off, a row
    /// that does nothing stays still.
    func hoverHighlight(
        isEnabled: Bool = true, cornerRadius: CGFloat = 7, opacity: Double = 0.08, vertical: CGFloat = 4
    ) -> some View {
        modifier(HoverHighlight(isEnabled: isEnabled, cornerRadius: cornerRadius, opacity: opacity, vertical: vertical))
    }
}

private struct HoverHighlight: ViewModifier {
    let isEnabled: Bool
    let cornerRadius: CGFloat
    let opacity: Double
    let vertical: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.primary.opacity(isHovered && isEnabled ? opacity : 0))
                    .padding(.horizontal, -5)
                    .padding(.vertical, -vertical)
            }
            .onHover { isHovered = $0 }
            .animation(Motion.hover, value: isHovered)
    }
}
