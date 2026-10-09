import SidelightCore
import SwiftUI

/// Text drawn as square dots in ``PixelFont``, like an LCD or LED display, in the current foreground style.
struct PixelText: View {
    private let line: PixelLine
    private let pixelSize: CGFloat
    private let showsUnlitPixels: Bool
    private let glows: Bool

    /// - Parameter pixelSize: Side of one dot in points; a text is seven dots tall. Keep it a multiple of 0.5 so
    ///   dots land on whole Retina pixels.
    init(_ text: String, pixelSize: CGFloat, showsUnlitPixels: Bool = false, glows: Bool = false) {
        line = PixelLine(text)
        self.pixelSize = pixelSize
        self.showsUnlitPixels = showsUnlitPixels
        self.glows = glows
    }

    var body: some View {
        // The canvas is larger than the text by the glow's reach, so the glow isn't clipped; the negative padding
        // keeps the text's own size for layout.
        let margin = glows ? pixelSize * 2 : 0
        Canvas { context, _ in
            context.translateBy(x: margin, y: margin)
            if showsUnlitPixels {
                context.fill(path(line.unlit), with: .style(.foreground.opacity(0.09)))
            }
            let lit = path(line.lit)
            if glows {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: pixelSize * 0.9))
                    layer.opacity = 0.75
                    layer.fill(lit, with: .foreground)
                }
            }
            context.fill(lit, with: .foreground)
        }
        .frame(
            width: CGFloat(line.columns) * pixelSize + 2 * margin,
            height: CGFloat(line.rows) * pixelSize + 2 * margin
        )
        .padding(-margin)
        .accessibilityHidden(true)
    }

    private func path(_ points: [PixelPoint]) -> Path {
        // A hairline gap between larger dots reads as a dot-matrix display; small ones would just look blurry.
        let gap: CGFloat = pixelSize >= 3 ? 0.25 : 0
        var path = Path()
        for point in points {
            path.addRect(
                CGRect(
                    x: CGFloat(point.column) * pixelSize, y: CGFloat(point.row) * pixelSize, width: pixelSize,
                    height: pixelSize
                )
                .insetBy(dx: gap, dy: gap))
        }
        return path
    }
}
