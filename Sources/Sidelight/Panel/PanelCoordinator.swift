import AppKit
import SidelightCore

/// One panel per display that shows it: creates, lays out and removes them as the configuration and the
/// connected displays change, and shows or hides them all together.
final class PanelCoordinator {
    private let environment: AppEnvironment
    private var panels: [Display.ID: PanelController] = [:]
    private var displays: [Display] = []
    /// The strip each panel reserves, by display; changes when panels resize, move or appear, but not when a
    /// fitted panel follows its content.
    private(set) var targetFrames: [Display.ID: CGRect] = [:]
    /// Hidden with the shortcut or the menu; not persisted.
    private(set) var isHidden = false

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
                let panel = PanelController(placement: placement, environment: environment)
                panels[display.id] = panel
                if !isHidden { panel.show() }
            }
        }

        let shownIDs = Set(shown.map(\.id))
        for (id, panel) in panels where !shownIDs.contains(id) {
            panel.close()
            panels[id] = nil
        }
    }
}
