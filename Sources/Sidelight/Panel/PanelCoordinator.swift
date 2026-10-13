import AppKit
import Observation
import SidelightCore
import os

/// One panel per display that shows it: creates, lays out and removes them as the configuration and the
/// connected displays change, and shows or hides them all together.
///
/// It also owns the details panel, which stands in for one display's panel while a widget shows more in it. Every
/// change to what the panels reserve (the details panel opening or closing, the panels hiding or showing) goes to
/// window avoidance as one step, from the strips before to the strips after.
@Observable
final class PanelCoordinator: DetailsPresenting {
    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var panels: [Display.ID: PanelController] = [:]
    @ObservationIgnored private var displays: [Display] = []
    @ObservationIgnored private var configuration = AppConfiguration()
    /// The strip each panel reserves, by display; changes when panels resize, move or appear, but not when a
    /// fitted panel follows its content.
    @ObservationIgnored private(set) var targetFrames: [Display.ID: CGRect] = [:]
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
    @ObservationIgnored private var detailsPanel: DetailsPanelController?
    @ObservationIgnored private let pendingCover = DelayedTask()

    /// Long enough that Mission Control, or a screen blanking for a moment, doesn't stop and restart services.
    static let unseenDelay: Duration = .seconds(60)
    /// Long enough that a quick look at the details panel doesn't stop and restart the covered panel's services.
    static let coverDelay: Duration = .seconds(5)

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
        targetFrames = [:]
        for display in shown {
            let placement = PanelMetrics.placement(of: display.panel(in: configuration), on: display)
            targetFrames[display.id] = placement.strip
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
        updateDetailsAfterChange(from: before)
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
            if session.widgetID != placement.widgetID || session.request != request {
                session.replace(widgetID: placement.widgetID, request: request)
                detailsPanel.window.setAccessibilityTitle(session.content.title)
            }
            detailsPanel.focus()
            return
        }

        let before = occupiedRegions
        if let previous = details {
            // Another display's details panel gives way: its panel comes back, in the same step as this one opens.
            detailsPanel?.close()
            detailsPanel = nil
            panels[previous.displayID]?.show()
        }
        let session = DetailsSession(displayID: display.id, widgetID: placement.widgetID, request: request)
        let controller = DetailsPanelController(
            session: session, placement: DetailsPlacement(display: display, replacing: panel.position),
            environment: environment
        ) { [weak self] in
            self?.closeDetails()
        }
        details = session
        detailsPanel = controller
        environment.hotkeys.register(configuration.details.closeHotkey, for: .closeDetails)

        // The panel's widgets stop drawing now, and stop needing data a little later.
        panel.hide()
        controller.show(focusing: true, slidingIn: true)
        updateCover()
        Log.details.info("Opened details on \(display.name, privacy: .public)")
        reservationsChanged(from: before)
    }

    /// Closes the details panel and gives its display its panel back. Search and choices are forgotten. With the
    /// panels hidden, it just ends the session: nothing shows.
    func closeDetails() {
        guard let session = details else { return }
        let before = occupiedRegions
        details = nil
        detailsPanel?.close()
        detailsPanel = nil
        environment.hotkeys.unregister(.closeDetails)
        if !isHidden { panels[session.displayID]?.show() }
        updateCover()
        Log.details.info("Closed details")
        reservationsChanged(from: before)
    }

    /// After the configuration or the displays changed: the details panel closes if what opened it is gone, and
    /// otherwise follows its display's new geometry. Window avoidance hears of it in the same step.
    private func updateDetailsAfterChange(from before: [PanelRegion]) {
        guard let session = details else { return }
        let display = displays.first { $0.id == session.displayID }
        let panel = display.map { $0.panel(in: configuration) }
        let widget = configuration.widget(session.widgetID)
        guard let display, let panel, panel.showsPanel, let widget, widget.isVisible(at: panel.position) else {
            // Its display was disconnected or stopped showing a panel, or the widget was removed or hidden there.
            closeDetails()
            return
        }
        environment.hotkeys.register(configuration.details.closeHotkey, for: .closeDetails)
        detailsPanel?.move(to: DetailsPlacement(display: display, replacing: panel.position))
        let old = before.first { $0.displayID == display.id }
        let new = occupiedRegions.first { $0.displayID == display.id }
        let isChanged =
            switch (old, new) {
            case (nil, nil): false
            case (let old?, let new?): !old.reservesSame(as: new)
            default: true
            }
        if isChanged { reservationsChanged(from: before) }
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

    private func reservationsChanged(from before: [PanelRegion]) {
        environment.windowAvoider.reservationsChanged(from: before)
    }
}
