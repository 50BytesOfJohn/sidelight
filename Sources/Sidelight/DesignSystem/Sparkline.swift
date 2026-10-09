import SwiftUI

/// Bar sparkline; the last (most recent) value is highlighted.
struct Sparkline: View {
    let values: [Int64]
    var height: CGFloat = 22

    var body: some View {
        let maximum = Double(max(values.max() ?? 1, 1))
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(values.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(index == values.count - 1 ? Color.accentColor : Color.primary.opacity(0.28))
                    .frame(height: max(2, height * Double(values[index]) / maximum))
            }
        }
        .frame(height: height)
        .animation(Motion.gentle, value: values)
    }
}
