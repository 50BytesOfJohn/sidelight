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
    /// Every container in one Docker context.
    case docker(context: DockerContextChoice)
    /// Every app, for the launcher `widget`, starting with `scope`.
    case appLauncher(widget: WidgetInstance.ID, scope: LauncherScope)
    /// A Runware account's usage, history and models, starting on `tab`.
    case runware(account: AccountID, tab: RunwareDetailsTab)
}

/// What the details panel shows, with the state it keeps while open: search text, choices, what's expanded. Nothing
/// of it is saved; closing the panel forgets it.
enum DetailsContent {
    case openRouterModels(OpenRouterCatalogueBrowser)
    case stash(StashBrowser)
    case docker(DockerBrowser)
    case appLauncher(AppLauncherBrowser)
    case runware(RunwareBrowser)

    init(_ request: DetailsRequest, stash: StashStore) {
        switch request {
        case .openRouterModels(let filter, let sort):
            self = .openRouterModels(OpenRouterCatalogueBrowser(filter: filter, sort: sort))
        case .stash(let composing):
            self = .stash(StashBrowser(store: stash, composing: composing))
        case .docker(let context):
            self = .docker(DockerBrowser(context: context))
        case .appLauncher(let widget, let scope):
            self = .appLauncher(AppLauncherBrowser(widgetID: widget, scope: scope))
        case .runware(let account, let tab):
            self = .runware(RunwareBrowser(account: account, tab: tab))
        }
    }

    /// Its title in the panel's header, and its name for VoiceOver.
    var title: String {
        switch self {
        case .openRouterModels: "OpenRouter Models"
        case .stash: "Stash"
        case .docker: "Docker"
        case .appLauncher: "Apps"
        case .runware: "Runware"
        }
    }

    /// Whose icon the header shows.
    var kind: WidgetKind {
        switch self {
        case .openRouterModels: .openRouter
        case .stash: .stash
        case .docker: .docker
        case .appLauncher: .appLauncher
        case .runware: .runware
        }
    }

    /// Takes `request` in place, keeping what it holds (search, selection), rather than starting over. Returns
    /// whether it did.
    func adopts(_ request: DetailsRequest) -> Bool {
        switch (self, request) {
        case (.stash(let browser), .stash(let composing)):
            if composing { browser.compose(closingAfter: true) }
            return true
        // The same context again keeps the search.
        case (.docker(let browser), .docker(let context)):
            return browser.context == context
        // The same launcher again keeps the search, and shows what it asked for.
        case (.appLauncher(let browser), .appLauncher(let widget, let scope)):
            guard browser.widgetID == widget else { return false }
            browser.scope = scope
            return true
        // The same account again keeps the search, and shows the tab asked for.
        case (.runware(let browser), .runware(let account, let tab)):
            guard browser.account == account else { return false }
            browser.tab = tab
            return true
        case (.openRouterModels, _), (.stash, _), (.docker, _), (.appLauncher, _), (.runware, _):
            return false
        }
    }

    /// Handles a key press before the window and its fields do, for content driven from the keyboard. Returns whether
    /// it did; it does nothing otherwise.
    func handlesKey(_ event: NSEvent) -> Bool {
        switch self {
        case .openRouterModels: false
        case .stash(let browser): browser.handlesKey(event)
        case .docker: false
        case .appLauncher(let browser): browser.handlesKey(event)
        case .runware: false
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
        case .stash, .docker, .appLauncher, .runware:
            return OpenRouterDemand()
        }
    }

    /// The account the content shows, details and activity both, as often as the widget that opened it refreshes.
    func runwareDemand(in configuration: AppConfiguration) -> RunwareDemand {
        guard case .runware(let browser) = content else { return RunwareDemand() }
        let cadence: RefreshCadence =
            if case .runware(let settings) = configuration.widget(widgetID)?.settings {
                settings.refresh
            } else {
                RunwareSettings().refresh
            }
        return RunwareDemand(
            accounts: [browser.account: RunwareAccountDemand(details: cadence, activity: cadence)],
            keptAccounts: [browser.account], isShown: true)
    }

    /// The Docker context the content shows, with its containers' CPU and memory, while it's on screen.
    func dockerDemand() -> DockerDemand {
        guard case .docker(let browser) = content else { return DockerDemand() }
        return DockerDemand(contexts: [browser.context], stats: browser.context)
    }

    /// Running apps, and the launcher's pinned ones, while the content lists them. This keeps the launcher's dots
    /// live behind it too, as the panel it covers stops counting.
    func appLauncherDemand(in configuration: AppConfiguration) -> AppLauncherDemand {
        guard case .appLauncher(let browser) = content else { return AppLauncherDemand() }
        var demand = AppLauncherDemand(isShown: true, listsRunning: true)
        if let widget = configuration.widget(browser.widgetID) {
            demand.pinned = configuration.appLauncherDemand(of: [widget]).pinned
        }
        return demand
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
