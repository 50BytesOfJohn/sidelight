import SwiftUI

/// The label of a sidebar row that adds something after the rows above it: a dashed tile, like a row still to come,
/// and a title. It brightens while the pointer is over it. Put it in a plain button, or a menu with a choice.
struct AddRowLabel: View {
    let title: String
    var size: CGFloat = 18
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: size * 0.5, weight: .bold))
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
                )
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(Motion.hover) { isHovered = hovering } }
    }
}
