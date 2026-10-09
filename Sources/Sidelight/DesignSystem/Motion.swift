import SwiftUI

/// The app's animation vocabulary. Use these instead of ad-hoc springs so motion feels consistent.
enum Motion {
    /// Value changes in data visualizations (rings, bars, sparklines).
    static let gentle = Animation.spring(response: 0.7, dampingFraction: 0.78)
    /// Direct feedback to the pointer: hover, toggles, selection.
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.72)
    /// Widgets being added, removed, reordered or resized.
    static let layout = Animation.spring(response: 0.45, dampingFraction: 0.86)
    /// Cards appearing when the panel is shown.
    static let entrance = Animation.spring(response: 0.6, dampingFraction: 0.8)
    /// A short overshoot to draw attention (usage crossing the warning threshold).
    static let pulse = Animation.spring(response: 0.35, dampingFraction: 0.55)
}
