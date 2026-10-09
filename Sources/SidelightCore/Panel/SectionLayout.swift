import CoreGraphics

/// How a panel divides its length along the edge among its sections.
public enum SectionLayout {
    /// Each section's length along the edge.
    ///
    /// Every section is at least as long as its content. Sections with a share split what the others leave of
    /// `available` by weight: one whose content is longer than its part keeps its content length, and the rest is
    /// split again among the others. Sections without a share are as long as their content, and so is every
    /// section once the content doesn't fit together; the panel then scrolls.
    ///
    /// - Parameters:
    ///   - content: Each section's natural length.
    ///   - shares: Each section's weight, or `nil` (or a weight that isn't positive) to fit its content.
    ///   - available: The panel's length. 0 stacks every section at its natural length, as a fitted panel does.
    ///   - spacing: The gap between neighbouring sections.
    public static func lengths(
        content: [CGFloat], shares: [Double?], available: CGFloat, spacing: CGFloat
    ) -> [CGFloat] {
        precondition(content.count == shares.count, "One share per section")
        let weights = shares.map { CGFloat(max($0 ?? 0, 0)) }
        var lengths = content
        var flexible = Set(weights.indices.filter { weights[$0] > 0 })
        let fixed = content.indices.filter { !flexible.contains($0) }.reduce(0) { $0 + content[$1] }
        var remaining = available - spacing * CGFloat(max(0, content.count - 1)) - fixed

        while !flexible.isEmpty {
            let unit = remaining / flexible.reduce(0) { $0 + weights[$1] }
            let overflowing = flexible.filter { content[$0] >= unit * weights[$0] }
            guard !overflowing.isEmpty else {
                for index in flexible { lengths[index] = unit * weights[index] }
                break
            }
            // These keep their content length; what's left is shared again among the rest.
            for index in overflowing { remaining -= content[index] }
            flexible.subtract(overflowing)
        }
        return lengths
    }

    /// The total length of sections this long, with `spacing` between neighbours.
    public static func totalLength(of lengths: [CGFloat], spacing: CGFloat) -> CGFloat {
        lengths.reduce(0, +) + spacing * CGFloat(max(0, lengths.count - 1))
    }
}
