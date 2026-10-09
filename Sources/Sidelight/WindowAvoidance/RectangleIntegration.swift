import AppKit
import Observation
import SidelightCore
import os

/// Makes Rectangle (or Rectangle Pro) leave a screen-edge gap for the panel, so its snapping cooperates
/// with window avoidance. Only runs when the user asks and confirms.
///
/// Rectangle reads its preferences at launch, so it's quit, reconfigured with `defaults`, and relaunched.
@Observable
final class RectangleIntegration {
    static let bundleIdentifiers = ["com.knollsoft.Rectangle", "com.knollsoft.Hookshot"]
    static let mainScreenOnlyKey = "screenEdgeGapsOnMainScreenOnly"
    static let quitTimeout: Duration = .seconds(5)

    static func gapKey(for position: PanelPosition) -> String {
        "screenEdgeGap" + position.rawValue.capitalized
    }

    /// What to write. Rectangle has one gap per screen edge, optionally limited to the main screen, so each edge
    /// with a panel gets room for the widest panel on it.
    struct Gaps: Equatable {
        var points: [PanelPosition: Int]
        var mainScreenOnly: Bool

        /// e.g. `screenEdgeGapLeft = 312`, one per edge.
        var assignments: [String] {
            PanelPosition.allCases.compactMap { edge in
                points[edge].map { "\(RectangleIntegration.gapKey(for: edge)) = \($0)" }
            }
        }
    }

    static func gaps(for configuration: AppConfiguration, displays: [Display]) -> Gaps {
        var points: [PanelPosition: Int] = [:]
        var mainScreenOnly = true
        for display in displays {
            let panel = display.panel(in: configuration)
            guard panel.showsPanel else { continue }
            let gap = Int(PanelMetrics.thickness(of: panel, on: display) + AvoidanceGeometry.gap)
            points[panel.position] = max(points[panel.position] ?? 0, gap)
            mainScreenOnly = mainScreenOnly && display.isMain
        }
        return Gaps(points: points, mainScreenOnly: mainScreenOnly)
    }

    private var installedBundleIdentifiers: [String] {
        Self.bundleIdentifiers.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    func configure(for configuration: AppConfiguration, displays: [Display]) {
        guard let identifiers = installedIdentifiersOrExplain() else { return }
        let gaps = Self.gaps(for: configuration, displays: displays)
        guard !gaps.points.isEmpty else {
            Alert.inform(title: "No panel to make room for", message: "The panel is hidden on every display.")
            return
        }
        guard
            Alert.confirm(
                title: "Configure Rectangle for the panel?",
                message: """
                    This will quit \(identifiers.joined(separator: ", ")), set \
                    \(gaps.assignments.joined(separator: ", ")) and \(Self.mainScreenOnlyKey) = \
                    \(gaps.mainScreenOnly), then relaunch it.

                    Rectangle's gaps apply to every display, so each edge gets room for its widest panel. \
                    Other edge gaps are left unchanged. Use "Revert Rectangle Configuration…" to undo.
                    """
            )
        else { return }

        Task {
            await restart(identifiers) {
                for identifier in identifiers {
                    for (edge, points) in gaps.points {
                        await Self.defaults(["write", identifier, Self.gapKey(for: edge), "-int", "\(points)"])
                    }
                    await Self.defaults([
                        "write", identifier, Self.mainScreenOnlyKey, "-bool", "\(gaps.mainScreenOnly)",
                    ])
                }
            }
        }
    }

    func revert() {
        guard let identifiers = installedIdentifiersOrExplain() else { return }
        let keys = PanelPosition.allCases.map(Self.gapKey(for:)) + [Self.mainScreenOnlyKey]
        guard
            Alert.confirm(
                title: "Revert Rectangle configuration?",
                message: """
                    This will quit \(identifiers.joined(separator: ", ")), delete \
                    \(keys.joined(separator: ", ")), then relaunch it.
                    """
            )
        else { return }

        Task {
            await restart(identifiers) {
                for identifier in identifiers {
                    for key in keys { await Self.defaults(["delete", identifier, key]) }
                }
            }
        }
    }

    private func installedIdentifiersOrExplain() -> [String]? {
        let identifiers = installedBundleIdentifiers
        guard identifiers.isEmpty else { return identifiers }
        Alert.inform(title: "Rectangle not found", message: "Neither Rectangle nor Rectangle Pro is installed.")
        return nil
    }

    /// Quits the apps, waits for them to exit, runs `change`, and relaunches them.
    private func restart(_ identifiers: [String], applying change: () async -> Void) async {
        var relaunchURLs: [URL] = []
        for identifier in identifiers {
            for application in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) {
                application.terminate()
                if let url = application.bundleURL { relaunchURLs.append(url) }
            }
        }

        let deadline = ContinuousClock.now + Self.quitTimeout
        while ContinuousClock.now < deadline,
            identifiers.contains(where: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty })
        {
            try? await Task.sleep(for: .milliseconds(100))
        }

        await change()

        for url in relaunchURLs {
            do {
                try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                Log.app.error("Can't relaunch \(url.lastPathComponent, privacy: .public): \(error)")
            }
        }
    }

    private static func defaults(_ arguments: [String]) async {
        let status = await ProcessRunner.run(URL(filePath: "/usr/bin/defaults"), arguments: arguments)
        Log.app.info("defaults \(arguments.joined(separator: " "), privacy: .public) exited with \(status)")
    }
}
