import SwiftUI

/// Small numeric badge (unread count) for minimal layouts.
struct CountBadge: View {
    let count: Int
    let color: Color

    var body: some View {
        Text(count > 9 ? "9+" : "\(count)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 15, minHeight: 15)
            .background(Capsule().fill(color))
            .overlay(Capsule().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
            .contentTransition(.numericText(value: Double(count)))
    }
}
