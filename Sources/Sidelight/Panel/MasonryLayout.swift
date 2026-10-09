import SwiftUI

/// Equal-width columns where each view goes into the currently shortest column, so cards of different heights
/// pack without gaps and still read roughly left to right, top to bottom. One column is a plain vertical stack.
struct MasonryLayout: Layout {
    var columns: Int
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        return CGSize(width: width, height: arrange(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, arrangement.origins) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: arrangement.columnWidth, height: nil)
            )
        }
    }

    private func arrange(
        _ subviews: Subviews, width: CGFloat
    ) -> (origins: [CGPoint], columnWidth: CGFloat, height: CGFloat) {
        let count = max(1, columns)
        let columnWidth = max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
        var heights = Array(repeating: CGFloat(0), count: count)
        var origins: [CGPoint] = []
        for subview in subviews {
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            origins.append(CGPoint(x: CGFloat(column) * (columnWidth + spacing), y: heights[column]))
            heights[column] += height + spacing
        }
        let height = max(0, (heights.max() ?? 0) - (subviews.isEmpty ? 0 : spacing))
        return (origins, columnWidth, height)
    }
}
