import Foundation
import Testing

@testable import SidelightCore

struct NoodleComputerTests {
    /// As `noodle-computer list` prints it in Noodle Computer 0.25.0: a desktop with a symbol, and a shell with a
    /// picture of its own.
    static let list = """
        {
          "computers" : [
            {
              "colour" : 3,
              "description" : "Builds the website",
              "hasWebDisplay" : true,
              "id" : "6F1C8E52-3B1A-4E43-9C55-2D7A1B0E9F11",
              "kind" : "Desktop",
              "name" : "Chloe’s Computer",
              "state" : "Running",
              "symbol" : "desktopcomputer"
            },
            {
              "colour" : 0,
              "hasWebDisplay" : false,
              "icon" : "iVBORw0KGgo=",
              "id" : "0B9D2C61-7E0F-4A8B-B1D3-5C6E7F8A9B0C",
              "kind" : "Shell",
              "name" : "Builder",
              "state" : "Starting…",
              "symbol" : "terminal"
            }
          ]
        }
        """

    @Test func `reads the computers it lists`() throws {
        let computers = try #require(NoodleComputer.list(json: Data(Self.list.utf8)))
        #expect(computers.count == 2)

        let desktop = computers[0]
        #expect(desktop.id == UUID(uuidString: "6F1C8E52-3B1A-4E43-9C55-2D7A1B0E9F11"))
        #expect(desktop.name == "Chloe’s Computer")
        #expect(desktop.description == "Builds the website")
        #expect(desktop.kind == "Desktop")
        #expect(desktop.state == .running)
        #expect(desktop.symbol == "desktopcomputer")
        #expect(desktop.colour == 3)
        #expect(desktop.icon == nil)
        #expect(desktop.hasDesktop)

        let shell = computers[1]
        #expect(shell.state == .starting)
        #expect(shell.icon == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(!shell.hasDesktop)
        #expect(shell.description == nil)
    }

    @Test func `skips entries it can't name and keeps the rest`() throws {
        let json = """
            {"computers": [
              {"id": "not-a-uuid", "name": "Broken"},
              {"id": "0B9D2C61-7E0F-4A8B-B1D3-5C6E7F8A9B0C"},
              {"id": "6F1C8E52-3B1A-4E43-9C55-2D7A1B0E9F11", "name": "Odd", "colour": "blue", "state": 4,
               "description": ""}
            ]}
            """
        let computers = try #require(NoodleComputer.list(json: Data(json.utf8)))
        #expect(computers.map(\.name) == ["Odd"])
        #expect(computers[0].colour == 0)
        #expect(computers[0].state == .other(""))
        #expect(computers[0].description == nil)
        #expect(computers[0].hasDesktop)
    }

    @Test(arguments: ["", "[]", "{}", #"{"computers": 3}"#])
    func `rejects output that isn't a list`(json: String) {
        #expect(NoodleComputer.list(json: Data(json.utf8)) == nil)
    }

    @Test(arguments: [
        ("Running", NoodleComputer.State.running),
        ("Starting…", .starting),
        ("Stopping...", .stopping),
        ("Stopped", .stopped),
        ("Upgrading…", .upgrading),
        ("Approval required", .needsSetup),
        ("Setup required", .needsSetup),
        ("Needs attention", .needsAttention),
        ("Hibernating", .other("Hibernating")),
    ])
    func `reads the states Noodle Computer labels`(label: String, state: NoodleComputer.State) {
        #expect(NoodleComputer.State(label: label) == state)
    }

    @Test(arguments: [
        (
            "noodle-computer: Noodle Computer is not accepting agents. Turn on “Allow agents” in its Settings, "
                + "under Agents.\n", NoodleComputerProblem.agentsOff
        ),
        ("noodle-computer: Agents are turned off in Settings.", .agentsOff),
        ("noodle-computer: Sidelight was not allowed to use this app.\n", .notAllowed),
        ("noodle-computer: This app's access was removed.", .notAllowed),
        ("noodle-computer: Nothing was lent.", .notLent),
        ("noodle-computer: There is nothing else to lend.", .nothingToLend),
        ("noodle-computer: Sandboxed apps cannot use this tool.", .failed("Sandboxed apps cannot use this tool.")),
        ("", .failed("Noodle Computer didn't answer.")),
    ])
    func `tells problems apart by the tool's message`(message: String, problem: NoodleComputerProblem) {
        #expect(NoodleComputerProblem(message: message) == problem)
    }

    @Test func `opens desktops on the desktop and shells in the terminal`() throws {
        let id = try #require(UUID(uuidString: "6F1C8E52-3B1A-4E43-9C55-2D7A1B0E9F11"))
        let desktop = NoodleComputer(id: id, name: "A", kind: "Desktop", state: .stopped, hasDesktop: true)
        let shell = NoodleComputer(id: id, name: "B", kind: "Shell", state: .stopped, hasDesktop: false)
        #expect(desktop.openURL.absoluteString == "noodlecomputer://6f1c8e52-3b1a-4e43-9c55-2d7a1b0e9f11?view=web")
        #expect(shell.openURL.absoluteString == "noodlecomputer://6f1c8e52-3b1a-4e43-9c55-2d7a1b0e9f11?view=terminal")
    }

    @Test func `widgets keep the chosen computer`() throws {
        let id = UUID()
        var configuration = AppConfiguration()
        configuration.sections = [
            PanelSection(widgets: [
                WidgetInstance(kind: .noodleComputer),
                WidgetInstance(settings: .noodleComputer(NoodleComputerSettings(computerID: id, computerName: "Box"))),
            ])
        ]
        #expect(try AppConfiguration(json: configuration.json()) == configuration)
    }

    @Test func `widgets saved without settings list every computer`() throws {
        let json = """
            {"id": "\(UUID().uuidString)", "kind": "noodleComputer", "showsInSidePanel": true, "showsInBar": true}
            """
        let widget = try JSONDecoder().decode(WidgetInstance.self, from: Data(json.utf8))
        #expect(widget.settings == .noodleComputer(NoodleComputerSettings()))
    }

    @Test func `the Widgets window's previews don't count as placed`() {
        var configuration = AppConfiguration()
        configuration.sections = [PanelSection(widgets: [WidgetInstance(kind: .clock)])]
        let previewing = configuration.serviceDemand(at: [.left], previewsEveryWidget: true)
        #expect(previewing.kinds.contains(.noodleComputer))
        #expect(!previewing.placedKinds.contains(.noodleComputer))

        var hidden = WidgetInstance(kind: .noodleComputer)
        hidden.showsInSidePanel = false
        configuration.sections[0].widgets.append(hidden)
        let demand = configuration.serviceDemand(at: [.left])
        #expect(!demand.kinds.contains(.noodleComputer))
        #expect(demand.placedKinds.contains(.noodleComputer))
    }
}
