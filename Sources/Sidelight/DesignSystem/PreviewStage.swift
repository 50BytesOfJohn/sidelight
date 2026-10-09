import SwiftUI

/// Dark gradient "desk" behind widget previews so glass and black chrome read well.
struct PreviewStage: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.12, blue: 0.32), Color(red: 0.05, green: 0.07, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [.purple.opacity(0.35), .clear], center: .topTrailing, startRadius: 10, endRadius: 260)
        }
    }
}
