import AppKit
import Observation
import SidelightCore
import os

/// One panel per display that shows it: creates, lays out and removes them as the configuration and the
/// connected displays change, and shows or hides them all together.
///
/// It also owns the details panel, which stands in for one display's panel while a widget shows more in it. Every
/// change to what the panels reserve (the details panel opening or closing, the panels hiding or showing, a panel
/// moving or resizing) goes to window avoidance as one step, from the strips before to the strips after.
@Observable
final class PanelCoordinator: DetailsPresenting {
    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var panels: [Display.ID: PanelController] = [:]
    @ObservationIgnored private var displays: [Display] = []
    @ObservationIgnored private var configuration = AppConfiguration()
    /// Hidden with the shortcut or the menu; not persisted. Hidden panels need no data and draw nothing.
    private(set) var isHidden = false
    /// Displays whose panel nobody has been able to see for ``unseenDelay``: the display sleeps, the screen is
    /// locked, or the screensaver runs. Like hidden panels, they need no data.
    private(set) var unseenDisplays: Set<Display.ID> = []
    @ObservationIgnored private var pendingUnseen: [Display.ID: DelayedTask] = [:]

    /// The details panel open in place of one display's panel, kept while the panels are hidden.
    private(set) var details: DetailsSession?
    /// The display whose panel the details panel has stood in for long enough that its widgets need no data.
    private(set) var coveredDisplay: Display.ID?
    /// Nobody has been able to see the details panel for ``unseenDelay``, as for a display's panel: it needs no data
    /// then. Watched on the details panel itself, never on the panel it covers, which is ordered out on purpose.
    private(set) var isDetailsUnseen = false
    @ObservationIgnored private var detailsPanel: DetailsPanelController?
    @ObservationIgnored private let pendingCover = DelayedTask()
    @ObservationIgnored private let pendingDetailsUnseen = DelayedTask()
    /// Told with window avoidance whenever the strips change, so Sidelight's own windows move out of the way too.
    @ObservationIgnored var onReservationsChanged: (_ settlingFor: Duration?) -> Void = { _ in }

    /// Long enough that Mission Control, or a screen blanking for a moment, doesn't stop and restart services.
    static let unseenDelay: Duration = .seconds(60)
    /// Long enough that a quick look at the details panel doesn't stop and restart the covered panel's services.
    static let coverDelay: Duration = .seconds(5)
    /// After a panel moves or resizes: long enough for its animation to finish, and for a dragged width slider to
    /// settle, before windows move out of its way.
    static let avoidanceSettleDelay: Duration = .milliseconds(600)

    init(environment: AppEnvironment) {
        self.environment = environment
        environment.details.presenter = self
    }

    /// What the panels keep clear, for window avoidance: each shown panel's strip, or the details panel's in place of
    /// the panel it covers. Nothing while hidden.
    var occupiedRegions: [PanelRegion] {
        guard !isHidden else { return [] }
        return displays.compactMap { display in
            if let details, details.displayID == display.id, let detailsPanel {
                let placement = detailsPanel.placement
                return PanelRegion(
                    displayID: display.id, role: .details, frame: placement.frame, visibleFrame: display.visibleFrame,
                    displayFrame: display.frame, edge: placement.edge)
            }
            guard let panel = panels[display.id], let frame = panel.occupiedFrame else { return nil }
            return PanelRegion(
                displayID: display.id, role: .main, frame: frame, visibleFrame: display.visibleFrame,
                displayFrame: display.frame, edge: panel.position)
        }
    }

    /// Hides everything, or shows it again: the details panel comes back with its search and scroll where they were.
    func toggle() {
        let before = occupiedRegions
        isHidden.toggle()
        for (id, panel) in panels {
            if isHidden {
                panel.hide()
            } else if id != details?.displayID {
                panel.show()
            }
        }
        if isHidden {
            detailsPanel?.hide()
        } else {
            detailsPanel?.show(focusing: false, slidingIn: false)
        }
        // Coming back from hidden, the covered panel's services weren't running: no reason to start them.
        updateCover(immediately: true)
        reservationsChanged(from: before)
    }

    func apply(_ configuration: AppConfiguration, displays newDisplays: [Display]) {
        let before = occupiedRegions
        // Display geometry changed under the panels: jump instead of animating from a stale frame.
        let animated = newDisplays == displays
        displays = newDisplays
        self.configuration = configuration

        let shown = newDisplays.filter { $0.panel(in: configuration).showsPanel }
        for display in shown {
            let placement = PanelMetrics.placement(of: display.panel(in: configuration), on: display)
            if let panel = panels[display.id] {
                panel.move(to: placement, animated: animated)
            } else {
                let id = display.id
                let panel = PanelController(placement: placement, environment: environment) { [weak self] in
                    self?.occlusionChanged(of: id, isOccluded: $0)
                }
                panels[display.id] = panel
                if !isHidden && details?.displayID != id { panel.show() }
            }
        }

        let shownIDs = Set(shown.map(\.id))
        for (id, panel) in panels where !shownIDs.contains(id) {
            panel.close()
            panels[id] = nil
            occlusionChanged(of: id, isOccluded: false)
        }
        updateDetailsAfterChange()
        // Windows move once the panels have settled, in one step with the details panel's changes.
        if !Self.reserveSame(before, occupiedRegions) {
            reservationsChanged(from: before, settlingFor: Self.avoidanceSettleDelay)
        }
    }

    /// Stops everything that runs on its own, before the app quits. Window avoidance puts windows back itself.
    func stop() {
        pendingCover.cancel()
        pendingDetailsUnseen.cancel()
        for pending in pendingUnseen.values { pending.cancel() }
        pendingUnseen = [:]
        detailsPanel?.close(animated: false)
        detailsPanel = nil
    }

    private func occlusionChanged(of id: Display.ID, isOccluded: Bool) {
        guard isOccluded else {
            pendingUnseen[id] = nil
            if unseenDisplays.contains(id) { unseenDisplays.remove(id) }
            return
        }
        let pending = pendingUnseen[id] ?? DelayedTask()
        pendingUnseen[id] = pending
        pending.schedule(after: Self.unseenDelay, tolerance: .seconds(5)) { [weak self] in
            self?.pendingUnseen[id] = nil
            self?.unseenDisplays.insert(id)
        }
    }

    // MARK: Details panel

    /// Opens `request` in place of the panel the widget at `placement` is drawn in. Asking for what's already open
    /// brings it forward; another widget's request on the same display replaces what it shows; one from another
    /// display moves the details panel there, and gives the first display its panel back, in one step.
    func openDetails(_ request: DetailsRequest, from placement: WidgetPlacement) {
        guard !isHidden, let display = displays.first(where: { $0.id == placement.displayID }),
            let panel = panels[display.id], configuration.widget(placement.widgetID) != nil
        else { return }

        if let session = details, session.displayID == display.id, let detailsPanel {
            if !session.adopt(request, from: placement.widgetID),
                session.widgetID != placement.widgetID || session.request != request
            {
                session.replace(widgetID: placement.widgetID, request: request)
                detailsPanel.window.setAccessibilityTitle(session.content.title)
            }
            detailsPanel.focus()
            return
        }

        let before = occupiedRegions
        if let previous = details {
            // Another display's details panel gives way: its panel comes back, in the same step as this one opens.
            endDetails(animated: true)
            panels[previous.displayID]?.show(animated: true)
        }
        let session = DetailsSession(
            displayID: display.id, widgetID: placement.widgetID, request: request, stash: environment.stash)
        let controller = DetailsPanelController(
            session: session, placement: DetailsPlacement(display: display, replacing: panel.position),
            environment: environment,
            close: { [weak self] in self?.closeDetails() },
            onVisibilityChange: { [weak self] in self?.detailsVisibilityChanged(isOnScreen: $0) })
        details = session
        detailsPanel = controller
        environment.hotkeys.register(configuration.details.closeHotkey, for: .closeDetails)

        // The panel slides out under the details panel sliding in. Its widgets stop drawing now, and stop needing
        // data a little later.
        panel.hide(animated: true)
        controller.show(focusing: true, slidingIn: true)
        updateCover()
        Log.details.info("Opened details on \(display.name, privacy: .public)")
        reservationsChanged(from: before, settlingFor: EdgeSlide.settleDelay)
    }

    /// Closes the details panel and gives its display its panel back, sliding in over it. Search and choices are
    /// forgotten. With the panels hidden, it just ends the session: nothing shows, and nothing moves.
    func closeDetails() {
        guard let session = details else { return }
        let before = occupiedRegions
        endDetails(animated: !isHidden)
        if !isHidden { panels[session.displayID]?.show(animated: true) }
        Log.details.info("Closed details")
        reservationsChanged(from: before, settlingFor: EdgeSlide.settleDelay)
    }

    /// Forgets the session and releases the details panel, after sliding it out if `animated`, leaving window
    /// avoidance to the caller.
    private func endDetails(animated: Bool = false) {
        details = nil
        detailsPanel?.close(animated: animated)
        detailsPanel = nil
        environment.hotkeys.unregister(.closeDetails)
        pendingDetailsUnseen.cancel()
        if isDetailsUnseen { isDetailsUnseen = false }
        updateCover()
    }

    /// The details panel can be seen again, or nobody can see it: after ``unseenDelay`` it needs no data, as a
    /// display's panel nobody can see.
    private func detailsVisibilityChanged(isOnScreen: Bool) {
        guard !isOnScreen else {
            pendingDetailsUnseen.cancel()
            if isDetailsUnseen { isDetailsUnseen = false }
            return
        }
        pendingDetailsUnseen.schedule(after: Self.unseenDelay, tolerance: .seconds(5)) { [weak self] in
            guard let self, details != nil else { return }
            isDetailsUnseen = true
        }
    }

    /// After the configuration or the displays changed: the details panel closes if what opened it is gone, and
    /// otherwise follows its display's new geometry. The caller tells window avoidance, in one step with the panels.
    private func updateDetailsAfterChange() {
        guard let session = details else { return }
        let display = displays.first { $0.id == session.displayID }
        let panel = display.map { $0.panel(in: configuration) }
        let widget = configuration.widget(session.widgetID)
        guard let display, let panel, panel.showsPanel, let widget, widget.isVisible(at: panel.position) else {
            // Its display was disconnected or stopped showing a panel, or the widget was removed or hidden there.
            Log.details.info("Closed details: what opened them is gone")
            endDetails()
            if !isHidden { panels[session.displayID]?.show() }
            return
        }
        environment.hotkeys.register(configuration.details.closeHotkey, for: .closeDetails)
        detailsPanel?.move(to: DetailsPlacement(display: display, replacing: panel.position))
    }

    /// The covered panel's widgets keep their data for ``coverDelay``, so a quick look doesn't stop and restart their
    /// services. Hidden panels need none anyway.
    private func updateCover(immediately: Bool = false) {
        guard let displayID = details?.displayID, !isHidden else {
            pendingCover.cancel()
            if coveredDisplay != nil { coveredDisplay = nil }
            return
        }
        guard coveredDisplay != displayID else { return }
        guard !immediately else {
            pendingCover.cancel()
            coveredDisplay = displayID
            return
        }
        coveredDisplay = nil
        pendingCover.schedule(after: Self.coverDelay) { [weak self] in
            guard let self, details?.displayID == displayID, !isHidden else { return }
            coveredDisplay = displayID
        }
    }

    /// Tells window avoidance the strips changed from `before`: now, as for hiding the panels, or once the panels
    /// have settled. Moving other apps' windows asks each of them over Accessibility and blocks the main thread, so
    /// it waits for a slide to finish rather than happen during it.
    private func reservationsChanged(from before: [PanelRegion], settlingFor delay: Duration? = nil) {
        environment.windowAvoider.reservationsChanged(from: before, settlingFor: delay)
        onReservationsChanged(delay)
    }

    /// Whether `old` and `new` keep the same strips clear on every display.
    private static func reserveSame(_ old: [PanelRegion], _ new: [PanelRegion]) -> Bool {
        guard old.count == new.count else { return false }
        return old.allSatisfy { region in
            new.contains { $0.displayID == region.displayID && $0.reservesSame(as: region) }
        }
    }
}
