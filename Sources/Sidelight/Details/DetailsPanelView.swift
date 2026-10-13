import SidelightCore
import SwiftUI

/// Everything in the details panel: the panel's background (or its own, with a custom style), a header with the
/// title and a close button that every widget's details share, and the content below.
struct DetailsPanelView: View {
    let session: DetailsSession
    let layout: DetailsLayout
    let close: () -> Void
    @Environment(ConfigurationStore.self) private var store
    @Environment(DesktopPictures.self) private var desktopPictures
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        let configuration = store.configuration
        let appearance = configuration.appearance.forDetailsPanel(configuration.details)
        let placement = layout.placement
        let margin = PanelMetrics.margin(isBar: false)
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let imageURL = appearance.background.image.url(desktopPictures: desktopPictures, displayID: placement.displayID)
        let content = session.content
        ZStack {
            PanelBackground(
                background: appearance.background, shape: shape,
                cutout: DesktopCutout(
                    displayID: placement.displayID, screen: placement.screenFrame,
                    rect: placement.frame.insetBy(dx: margin, dy: margin), anchor: .center))
            VStack(spacing: 0) {
                DetailsHeader(title: content.title, metadata: content.kind.metadata, close: close)
                DetailsContentView(content: content)
                    .id(session.contentID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .clipShape(shape)
        }
        .padding(margin)
        .environment(\.colorScheme, appearance.colorScheme(system: systemColorScheme, imageURL: imageURL))
        .environment(\.isPanelShown, layout.isShown)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.title)
    }
}

/// The title and the close button, the same for every widget's details.
private struct DetailsHeader: View {
    let title: String
    let metadata: WidgetMetadata
    let close: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            WidgetIcon(metadata: metadata, size: 11)
                .foregroundStyle(.secondary)
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 6)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
            .accessibilityLabel("Close \(title)")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

/// The content of a details panel, by what it shows. Each widget's details live in its own folder.
private struct DetailsContentView: View {
    let content: DetailsContent

    var body: some View {
        switch content {
        case .openRouterModels(let browser): OpenRouterCatalogueView(browser: browser)
        }
    }
}
