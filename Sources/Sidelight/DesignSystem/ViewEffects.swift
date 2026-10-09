import SwiftUI

extension View {
    /// A one-shot light sweep across the view whenever `trigger` changes.
    func shimmer(on trigger: some Equatable, cornerRadius: CGFloat = 16) -> some View {
        modifier(Shimmer(trigger: trigger, cornerRadius: cornerRadius))
    }

    /// A spring entrance that runs once when the view appears, delayed by its position in a list.
    func staggeredEntrance(index: Int) -> some View {
        modifier(StaggeredEntrance(index: index))
    }
}

private struct Shimmer<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    let cornerRadius: CGFloat
    @State private var offset: CGFloat = -1.2

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.6)
                    .offset(x: offset * proxy.size.width)
                    .blendMode(.plusLighter)
                }
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .onChange(of: trigger) {
                offset = -1.2
                withAnimation(.easeOut(duration: 0.9)) { offset = 1.6 }
            }
    }
}

private struct StaggeredEntrance: ViewModifier {
    let index: Int
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown ? 0 : 16)
            .scaleEffect(isShown ? 1 : 0.97, anchor: .top)
            .onAppear {
                withAnimation(Motion.entrance.delay(0.05 + Double(index) * 0.06)) { isShown = true }
            }
    }
}
