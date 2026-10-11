import Foundation
import SidelightCore

// Generate a session-only development configuration without reading any user's config.
var configuration = AppConfiguration()
configuration.sections = [PanelSection(widgets: [WidgetInstance(kind: .agentSessions)], share: nil)]
configuration.panel.length = .fit
configuration.panel.alignment = .center
configuration.windowAvoidance = .off
configuration.updates = UpdateSettings(checksAutomatically: false, installsAutomatically: false)
configuration.appearance.background.kind = .color
configuration.appearance.background.color.fill = .solid
configuration.appearance.background.color.color = RGBAColor(hex: "#202025")!
configuration.appearance.text = .light
if let destination = CommandLine.arguments.dropFirst().first, destination != "--diagnose" {
    try configuration.json().write(to: URL(filePath: destination))
}
print("HOME=\(URL.homeDirectory.path)")
print("SUPPORT=\(URL.applicationSupportDirectory.path)")

if CommandLine.arguments.contains("--diagnose") {
    print("LOCK_DIR=\(CodexThreadLocks.defaultDirectory.path(percentEncoded: false))")
    let processes = ProcessTable.snapshot() ?? []
    let fixturePIDs =
        (try? JSONDecoder().decode(
            [Int32].self, from: Data(contentsOf: URL.homeDirectory.appending(path: "fixture-processes.json")))) ?? []
    for process in processes where fixturePIDs.contains(process.pid) {
        print("FIXTURE_HOST=\(process.pid):\(process.name)")
        if process.name == "codex" { print("OPEN_FILES=\(ProcessTable.openFiles(of: process.pid, withPrefix: "/"))") }
    }
    print(
        "LOCK_HOLDERS=\(CodexThreadLocks.holders(processes: processes.filter { fixturePIDs.contains($0.pid) }).count)")
}
