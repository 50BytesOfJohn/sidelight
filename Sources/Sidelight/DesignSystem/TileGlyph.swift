import SidelightCore
import SwiftUI

/// A small picture of where a window action puts the window: the tile itself for halves, corners, thirds and
/// maximize, a symbol for the rest. Follows the text color, so it reads in light and dark.
struct TileGlyph: View {
    let action: WindowAction
    var size = CGSize(width: 22, height: 15)

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(.secondary, lineWidth: 1.25)
            if let unit = action.unitRect() {
                let inset: CGFloat = 2.5
                let width = size.width - inset * 2
                let height = size.height - inset * 2
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(.primary.opacity(0.8))
                    .frame(width: width * (unit.maxX - unit.minX) - 0.5, height: height * (unit.maxY - unit.minY) - 0.5)
                    .offset(x: inset + width * unit.minX, y: inset + height * unit.minY)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size.height * 0.55, weight: .semibold))
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch action {
        case .center: "plus"
        case .restore: "arrow.uturn.backward"
        case .nextDisplay: "arrow.right"
        case .previousDisplay: "arrow.left"
        default: "square"
        }
    }
}
