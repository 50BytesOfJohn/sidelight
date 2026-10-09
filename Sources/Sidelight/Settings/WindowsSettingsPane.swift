import SidelightCore
import SwiftUI

/// How other apps' windows are kept out from under the panel, and the Rectangle integration.
struct WindowsSettingsPane: View {
    @Environment(ConfigurationStore.self) private var store
    @Environment(DisplayMonitor.self) private var monitor
    @Environment(WindowAvoider.self) private var windowAvoider
    @Environment(RectangleIntegration.self) private var rectangle

    var body: some View {
        @Bindable var store = store
        let configuration = store.configuration

        Form {
            Section {
                Picker("Overlapping windows", selection: $store.configuration.windowAvoidance) {
                    ForEach(WindowAvoidanceMode.allCases) { mode in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title)
                            Text(mode.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Windows on every display with a panel are kept clear of it.").settingsFootnote()
            }

            Section {
                LabeledContent("Accessibility access") {
                    if windowAvoider.isTrusted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") { windowAvoider.requestAccess() }
                    }
                }
                LabeledContent("Windows already under the panel") {
                    Button("Move Them Now") { windowAvoider.avoidAllWindows() }
                        .disabled(!windowAvoider.isTrusted || configuration.windowAvoidance == .off)
                }
            } footer: {
                if !windowAvoider.isTrusted {
                    Text("macOS only lets Sidelight move other apps' windows with Accessibility access.")
                        .settingsFootnote()
                }
            }

            Section {
                let gaps = RectangleIntegration.gaps(for: configuration, displays: monitor.displays)
                LabeledContent("Screen-edge gaps") {
                    Text(gaps.assignments.isEmpty ? "No panel shown" : gaps.assignments.joined(separator: "\n"))
                        .font(.callout.monospaced())
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Revert…") { rectangle.revert() }
                    Button("Configure Rectangle…") {
                        rectangle.configure(for: store.configuration, displays: monitor.displays)
                    }
                }
            } header: {
                Text("Rectangle")
            } footer: {
                Text(
                    "Rectangle and Rectangle Pro snap windows using their own screen-edge gaps. Sidelight can set them to fit the panel; it quits and relaunches Rectangle to apply them."
                )
                .settingsFootnote()
            }
        }
    }
}
