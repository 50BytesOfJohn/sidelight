import SidelightCore
import SwiftUI

/// Logos of the services widgets read, bundled in `ProviderLogos.xcassets`. See docs/BRAND_ASSETS.md.
enum BrandLogos {
    /// Older SwiftPM accessors search beside the executable, rather than in the app's Resources directory.
    static let bundle: Bundle = {
        guard let url = Bundle.main.url(forResource: "Sidelight_Sidelight", withExtension: "bundle"),
            let bundle = Bundle(url: url)
        else { return .module }
        return bundle
    }()

    /// A one-color logo, drawn in the foreground style like a symbol and scaled to `size` points.
    static func template(_ name: String, size: CGFloat) -> some View {
        Image(name, bundle: bundle)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A widget kind's icon: its service's logo when it has one, otherwise its symbol, in the foreground style.
struct WidgetIcon: View {
    let metadata: WidgetMetadata
    /// The symbol's point size; a logo is drawn a little larger, to match a symbol's visual weight.
    let size: CGFloat

    var body: some View {
        if let logo = metadata.logo {
            BrandLogos.template(logo, size: size * 1.15)
        } else {
            Image(systemName: metadata.systemImage).font(.system(size: size, weight: .semibold))
        }
    }
}

/// An agent's logo in its own colors, as bundled in `ProviderLogos.xcassets`: the asset catalog picks the light or
/// dark artwork for the appearance.
struct ProviderLogo: View {
    let provider: AgentProvider
    let size: CGFloat

    var body: some View {
        Image(provider.logoAsset, bundle: BrandLogos.bundle)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension AgentProvider {
    /// The image set in `ProviderLogos.xcassets`; the same artwork the AI Usage widget shows.
    var logoAsset: String {
        switch self {
        case .codex: "AIUsageCodex"
        case .claudeCode: "AIUsageClaude"
        case .cursor: "AIUsageCursor"
        case .openCode: "AgentOpenCode"
        }
    }
}
