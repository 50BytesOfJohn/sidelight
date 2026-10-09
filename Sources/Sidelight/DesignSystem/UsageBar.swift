import SwiftUI

/// Horizontal usage meter.
struct UsageBar: View {
    let percent: Double
    /// Turn off for values that update on a timer: a constantly running animation keeps SwiftUI busy.
    var isAnimated = true
    var height: CGFloat = 7

    var body: some View {
        let color = Color.usage(percent: percent)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(
                        LinearGradient(colors: [color.opacity(0.65), color], startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: max(height, proxy.size.width * percent / 100))
            }
        }
        .frame(height: height)
        .animation(isAnimated ? Motion.gentle : nil, value: percent)
    }
}

/// Tiny vertical usage meter for minimal layouts.
struct VerticalUsageBar: View {
    let percent: Double
    var width: CGFloat = 6
    var height: CGFloat = 28

    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule().fill(Color.primary.opacity(0.12))
            Capsule()
                .fill(Color.usage(percent: percent))
                .frame(height: max(width, height * percent / 100))
        }
        .frame(width: width, height: height)
    }
}
