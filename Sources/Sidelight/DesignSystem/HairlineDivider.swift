import SwiftUI

/// A half-point line across a widget, between its blocks or rows. Add vertical padding to space it.
struct HairlineDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
    }
}
