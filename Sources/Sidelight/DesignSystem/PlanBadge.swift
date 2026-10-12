import SwiftUI

/// A plan's name in small capitals on a capsule of its provider's color: `PRO`, `MAX`.
struct PlanBadge: View {
    let name: String
    let tint: Color

    var body: some View {
        Text(name.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.16)))
    }
}
