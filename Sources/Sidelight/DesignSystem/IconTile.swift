import SwiftUI

/// App-icon-style rounded tile with a symbol, used to represent a widget kind.
struct IconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 30
    /// A logo in `ProviderLogos.xcassets` to draw instead of the symbol.
    var logo: String?

    var body: some View {
        Group {
            if let logo {
                BrandLogos.template(logo, size: size * 0.56)
            } else {
                Image(systemName: systemImage).font(.system(size: size * 0.46, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.65)], startPoint: .top, endPoint: .bottom))
        )
        .shadow(color: tint.opacity(0.35), radius: 3, y: 1)
    }
}
