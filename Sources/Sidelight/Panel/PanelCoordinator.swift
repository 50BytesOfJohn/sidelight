import AppKit
import Observation
import SidelightCore

/// One panel per display that shows it: creates, lays out and removes them as the configuration and the
/// connected displays change, and shows or hides them all together.
@Observable
final class PanelCoordinator {
    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var panels: [Display.ID: PanelController] = [:]
    @ObservationIgnored private var displays: [Display] = []
    /// The strip each panel reserves, by display; changes when panels resize, move or appear, but not when a
    /// fitted panel follows its content.
    @ObservationIgnored private(set) var targetFrames: [Display.ID: CGRect] = [:]
    /// Hidden with the shortcut or the menu; not persisted. Hidden panels need no data and draw nothing.
    private(set) var isHidden = false
    /// Displays whose panel nobody has been able to see for ``unseenDelay``: the display sleeps, the screen is
    /// locked, or the screensaver runs. Like hidden panels, they need no data.
    private(set) var unseenDisplays: Set<Display.ID> = []
    @ObservationIgnored private var pendingUnseen: [Display.ID: DelayedTask] = [:]

    /// Long enough that Mission Control, or a screen blanking for a moment, doesn't stop and restart services.
    static let unseenDelay: Duration = .seconds(60)

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Where the panels are, for window avoidance.
    var occupiedRegions: [PanelRegion] {
        displays.compactMap { display in
            guard let panel = panels[display.id], let frame = panel.occupiedFrame else { return nil }
            return PanelRegion(frame: frame, visibleFrame: display.visibleFrame, edge: panel.position)
        }
    }

    func toggle() {
        isHidden.toggle()
        for panel in panels.values {
            if isHidden { panel.hide() } else { panel.show() }
        }
    }

    func apply(_ configuration: AppConfiguration, displays newDisplays: [Display]) {
        // Display geometry changed under the panels: jump instead of animating from a stale frame.
        let animated = newDisplays == displays
        displays = newDisplays

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
                if !isHidden { panel.show() }
            }
        }

        let shownIDs = Set(shown.map(\.id))
        for (id, panel) in panels where !shownIDs.contains(id) {
            panel.close()
            panels[id] = nil
            occlusionChanged(of: id, isOccluded: false)
        }
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
}
