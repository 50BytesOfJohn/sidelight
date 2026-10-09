import SidelightCore
import SwiftUI

/// Lays a panel's sections out along its edge, each as long as ``SectionLayout`` makes it, and together at least
/// `available` long. Each section is proposed its whole length, so it can align its widgets inside it.
struct SectionStack: Layout {
    var axis: Axis
    /// One per subview: the section's weight, or `nil` to fit its widgets.
    var shares: [Double?]
    var spacing: CGFloat
    /// The visible length to share out; 0 stacks every section at its natural length.
    var available: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let cross = crossLength(proposal, subviews: subviews)
        let length = max(SectionLayout.totalLength(of: lengths(subviews, cross: cross), spacing: spacing), available)
        return axis == .vertical ? CGSize(width: cross, height: length) : CGSize(width: length, height: cross)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cross = axis == .vertical ? bounds.width : bounds.height
        var offset: CGFloat = 0
        for (subview, length) in zip(subviews, lengths(subviews, cross: cross)) {
            // Whole-point origins keep text crisp when shares divide the length unevenly.
            let start = offset.rounded()
            let end = (offset + length).rounded()
            if axis == .vertical {
                subview.place(
                    at: CGPoint(x: bounds.minX, y: bounds.minY + start), anchor: .topLeading,
                    proposal: ProposedViewSize(width: cross, height: end - start))
            } else {
                subview.place(
                    at: CGPoint(x: bounds.minX + start, y: bounds.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: end - start, height: cross))
            }
            offset += length + spacing
        }
    }

    private func lengths(_ subviews: Subviews, cross: CGFloat) -> [CGFloat] {
        let natural = subviews.map { subview in
            axis == .vertical
                ? subview.sizeThatFits(ProposedViewSize(width: cross, height: nil)).height
                : subview.sizeThatFits(ProposedViewSize(width: nil, height: cross)).width
        }
        let shares = subviews.indices.map { self.shares.indices.contains($0) ? self.shares[$0] : nil }
        return SectionLayout.lengths(content: natural, shares: shares, available: available, spacing: spacing)
    }

    /// The extent across the edge: what's proposed, or else the widest section.
    private func crossLength(_ proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        if let proposed = axis == .vertical ? proposal.width : proposal.height { return proposed }
        return subviews.map { subview in
            let size = subview.sizeThatFits(.unspecified)
            return axis == .vertical ? size.width : size.height
        }.max() ?? 0
    }
}

extension PanelAlignment {
    /// Where a side panel's section puts its widgets: top, middle or bottom.
    var verticalAlignment: Alignment {
        switch self {
        case .start: .top
        case .center: .center
        case .end: .bottom
        }
    }

    /// Where a bar's section puts its widgets: left, center or right.
    var horizontalAlignment: Alignment {
        switch self {
        case .start: .leading
        case .center: .center
        case .end: .trailing
        }
    }
}
