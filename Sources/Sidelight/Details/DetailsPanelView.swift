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
        let chrome = PanelChrome(appearance.shape, edge: placement.edge)
        let shape = chrome.outline
        let imageURL = appearance.background.image.url(desktopPictures: desktopPictures, displayID: placement.displayID)
        let content = session.content
        ZStack {
            PanelBackground(
                background: appearance.background, shape: shape,
                cutout: DesktopCutout(
                    displayID: placement.displayID, screen: placement.screenFrame,
                    rect: chrome.background(in: placement.frame), anchor: .center))
            // macOS passes mouse events through a window's fully transparent pixels to the app behind, so with no
            // background, scrolling between two rows would scroll that app instead. This fill is too faint to see,
            // but it makes every point of the panel its own.
            shape.fill(Color.black.opacity(0.01))
            VStack(spacing: 0) {
                DetailsHeader(title: content.title, metadata: content.kind.metadata, close: close)
                DetailsContentView(content: content)
                    .id(session.contentID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(chrome.padding)
            .clipShape(shape)
        }
        .padding(chrome.margins)
        // Its content sits straight on its background, never on cards: the text is chosen for that background.
        .environment(
            \.colorScheme, appearance.colorScheme(system: systemColorScheme, imageURL: imageURL, onCards: false)
        )
        // Stops minute redraws while it's hidden with the panels, or nobody can see it.
        .environment(\.isPanelShown, layout.isOnScreen)
        .environment(\.closeDetails, CloseDetailsAction(run: close))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.title)
    }
}

/// Closes the details panel, for content that's done once something is chosen, like the launcher's.
struct CloseDetailsAction {
    let run: () -> Void

    func callAsFunction() { run() }
}

extension EnvironmentValues {
    @Entry var closeDetails: CloseDetailsAction?
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
        case .stash(let browser): StashDetailsView(browser: browser)
        case .docker(let browser): DockerDetailsView(browser: browser)
        case .appLauncher(let browser): AppLauncherDetailsView(browser: browser)
        case .runware(let browser): RunwareDetailsView(browser: browser)
        }
    }
}
