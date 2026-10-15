import AppKit
import Observation
import SidelightCore
import SwiftUI

/// What a widget asks the details panel to show. Equal requests from the same widget are the same session: asking
/// again brings it forward rather than starting over.
enum DetailsRequest: Hashable {
    /// Every OpenRouter model, starting with this filter and order.
    case openRouterModels(filter: OpenRouterModelFilter, sort: OpenRouterModelSort)
    /// The whole stash; `composing` opens a new item's editor, and Esc there goes back to the app you were in.
    case stash(composing: Bool)
}

/// What the details panel shows, with the state it keeps while open: search text, choices, what's expanded. Nothing
/// of it is saved; closing the panel forgets it.
enum DetailsContent {
    case openRouterModels(OpenRouterCatalogueBrowser)
    case stash(StashBrowser)

    init(_ request: DetailsRequest, stash: StashStore) {
        switch request {
        case .openRouterModels(let filter, let sort):
            self = .openRouterModels(OpenRouterCatalogueBrowser(filter: filter, sort: sort))
        case .stash(let composing):
            self = .stash(StashBrowser(store: stash, composing: composing))
        }
    }

    /// Its title in the panel's header, and its name for VoiceOver.
    var title: String {
        switch self {
        case .openRouterModels: "OpenRouter Models"
        case .stash: "Stash"
        }
    }

    /// Whose icon the header shows.
    var kind: WidgetKind {
        switch self {
        case .openRouterModels: .openRouter
        case .stash: .stash
        }
    }

    /// Takes `request` in place, keeping what it holds (search, selection), rather than starting over. Returns
    /// whether it did.
    func adopts(_ request: DetailsRequest) -> Bool {
        switch (self, request) {
        case (.stash(let browser), .stash(let composing)):
            if composing { browser.compose(closingAfter: true) }
            return true
        case (.openRouterModels, _), (.stash, _):
            return false
        }
    }

    /// Handles a key press before the window and its fields do, for content driven from the keyboard. Returns whether
    /// it did; it does nothing otherwise.
    func handlesKey(_ event: NSEvent) -> Bool {
        switch self {
        case .openRouterModels: false
        case .stash(let browser): browser.handlesKey(event)
        }
    }
}

/// The details panel open on one display, in place of its panel, for one widget.
@Observable
final class DetailsSession {
    let displayID: Display.ID
    private(set) var widgetID: WidgetInstance.ID
    private(set) var request: DetailsRequest
    private(set) var content: DetailsContent
    /// Changes whenever the content is replaced, so its views start fresh.
    private(set) var contentID = UUID()
    /// The stash, for the stash's content.
    private let stash: StashStore

    init(displayID: Display.ID, widgetID: WidgetInstance.ID, request: DetailsRequest, stash: StashStore) {
        self.displayID = displayID
        self.widgetID = widgetID
        self.request = request
        self.stash = stash
        content = DetailsContent(request, stash: stash)
    }

    /// Shows what another widget, or another of this widget's lists, asked for, in the same panel.
    func replace(widgetID: WidgetInstance.ID, request: DetailsRequest) {
        self.widgetID = widgetID
        self.request = request
        content = DetailsContent(request, stash: stash)
        contentID = UUID()
    }

    /// Takes what a widget asked for into the content already open, when that content can: the stash's + button
    /// while the stash is open opens a new item's editor, keeping the search and selection. Returns whether it did.
    func adopt(_ request: DetailsRequest, from widgetID: WidgetInstance.ID) -> Bool {
        guard content.adopts(request) else { return false }
        self.widgetID = widgetID
        self.request = request
        return true
    }

    /// What the content needs fetched while it's on screen, given the widget that opened it.
    func openRouterDemand(in configuration: AppConfiguration) -> OpenRouterDemand {
        switch content {
        case .openRouterModels:
            guard case .openRouter(let settings) = configuration.widget(widgetID)?.settings else {
                return OpenRouterDemand()
            }
            return OpenRouterDemand(catalogue: settings.sync)
        case .stash:
            return OpenRouterDemand()
        }
    }
}

/// Who opens the details panel: the panel coordinator, which swaps it with the panel it replaces.
protocol DetailsPresenting: AnyObject {
    func openDetails(_ request: DetailsRequest, from placement: WidgetPlacement)
}

/// How widgets inside a panel open the details panel. The panel coordinator does the work; views reach it through
/// the environment, as they reach services.
@Observable
final class DetailsPresenter {
    @ObservationIgnored weak var presenter: (any DetailsPresenting)?

    /// Opens `request` in place of the panel the widget at `placement` is in.
    func open(_ request: DetailsRequest, from placement: WidgetPlacement) {
        presenter?.openDetails(request, from: placement)
    }
}

/// Where a widget is drawn: in which display's panel, as which widget. Only real panels set it; previews in the
/// Widgets window and the builder don't, so they never open a details panel over the real one.
struct WidgetPlacement: Hashable {
    let displayID: Display.ID
    let widgetID: WidgetInstance.ID
}

extension EnvironmentValues {
    @Entry var widgetPlacement: WidgetPlacement?
}
