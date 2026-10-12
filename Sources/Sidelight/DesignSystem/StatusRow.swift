import SwiftUI

/// A colored dot and a line of status text, as settings forms show where a widget's data comes from and how that's
/// going. `trailing` sits after the text, in the same row: a ``RefreshButton``, say.
struct StatusRow<Content: View, Trailing: View>: View {
    let color: Color
    var dotSize: CGFloat = 7
    /// `.firstTextBaseline` keeps the dot with the first line of text that wraps.
    var alignment = VerticalAlignment.center
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: alignment, spacing: 6) {
            Circle().fill(color).frame(width: dotSize, height: dotSize)
            content
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            trailing
        }
    }
}

extension StatusRow where Content == Text {
    init(
        color: Color, text: String, dotSize: CGFloat = 7, alignment: VerticalAlignment = .center,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(color: color, dotSize: dotSize, alignment: alignment, content: { Text(text) }, trailing: trailing)
    }
}

extension StatusRow where Trailing == EmptyView {
    init(
        color: Color, dotSize: CGFloat = 7, alignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> Content
    ) {
        self.init(color: color, dotSize: dotSize, alignment: alignment, content: content, trailing: { EmptyView() })
    }
}

extension StatusRow where Content == Text, Trailing == EmptyView {
    init(color: Color, text: String, dotSize: CGFloat = 7, alignment: VerticalAlignment = .center) {
        self.init(color: color, text: text, dotSize: dotSize, alignment: alignment, trailing: { EmptyView() })
    }
}

/// A small icon-only button that asks a service to fetch again, with `help` as its tooltip.
struct RefreshButton: View {
    let help: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button("Refresh", systemImage: "arrow.clockwise", action: action)
            .labelStyle(.iconOnly)
            .disabled(isDisabled)
            .help(help)
    }
}
