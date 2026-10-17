import AppKit
import SidelightCore
import SwiftUI
import UniformTypeIdentifiers

struct AppLauncherSettingsEditor: View {
    @Binding var settings: AppLauncherSettings
    @Environment(AppLauncherService.self) private var service
    @Environment(WindowAvoider.self) private var windowAvoider

    var body: some View {
        apps
        Picker("Icon size", selection: $settings.iconSize) {
            ForEach(AppLauncherSettings.iconSizeChoices, id: \.self) { size in
                Text("\(size) pt").tag(size)
            }
            if !AppLauncherSettings.iconSizeChoices.contains(settings.iconSize) {
                Text("\(settings.iconSize) pt (custom)").tag(settings.iconSize)
            }
        }
        Picker("Spacing", selection: $settings.spacing) {
            Text("Tight").tag(LauncherSpacing.tight)
            Text("Regular").tag(LauncherSpacing.regular)
            Text("Roomy").tag(LauncherSpacing.roomy)
        }
        .pickerStyle(.segmented)
        countRow("Columns", value: $settings.columns, range: AppLauncherSettings.columnRange, zero: "Fit")
        countRow("Rows", value: $settings.rows, range: AppLauncherSettings.rowRange, zero: "All")
        Stepper("In the bar: \(settings.barCount)", value: $settings.barCount, in: AppLauncherSettings.barCountRange)
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Show names", isOn: $settings.showsNames)
            SettingsCaption("In the regular layout.")
        }
        Toggle("Running dots", isOn: $settings.showsRunningIndicator)
        Toggle("Running apps not in the launcher", isOn: $settings.showsRunningApps)
        Toggle("All Apps tile", isOn: $settings.showsAllAppsTile)
        ExpandableRow(title: "Advanced") {
            InfoLabel(
                "New Window",
                info: "New Window presses the app's own New Window menu item, through Accessibility, the access "
                    + "window avoidance uses. Without it, the menu doesn't offer New Window.")
            StatusRow(
                color: windowAvoider.isTrusted ? .green : .orange,
                text: windowAvoider.isTrusted ? "New Window available" : "New Window needs Accessibility access"
            ) {
                if !windowAvoider.isTrusted {
                    Spacer(minLength: 4)
                    Button("Grant Access…") { windowAvoider.requestAccess() }
                }
            }
        }
    }

    // MARK: Apps

    private var apps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Apps")
            if settings.apps.isEmpty {
                SettingsCaption("None yet. Add some, or drop apps on the widget.")
            } else {
                List {
                    ForEach(settings.apps) { app in
                        appRow(app)
                    }
                    .onMove { settings.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(height: min(Double(settings.apps.count) * 28 + 8, 220))
                .listStyle(.bordered)
            }
            Button("Add Apps…", action: addApps)
        }
    }

    private func appRow(_ app: LauncherApp) -> some View {
        let isMissing = service.resolve(app) == .missing
        return HStack(spacing: 6) {
            Image(nsImage: AppIcons.icon(atPath: service.resolve(app).url?.path(percentEncoded: false) ?? app.path))
                .resizable()
                .frame(width: 18, height: 18)
                .opacity(isMissing ? 0.4 : 1)
            Text(app.name).lineLimit(1)
            if isMissing {
                Text("Not found").foregroundStyle(.orange).font(.caption)
            }
            Spacer(minLength: 4)
            Button {
                settings.remove(app.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove \(app.name)")
            .accessibilityLabel("Remove \(app.name)")
        }
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        settings.add(LauncherDropDelegate.apps(in: panel.urls))
    }

    /// A stepper where 0 means "Fit" or "All".
    private func countRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, zero: String) -> some View {
        HStack {
            Stepper(
                "\(title): \(value.wrappedValue == 0 ? zero : "\(value.wrappedValue)")", value: value, in: range)
        }
    }
}
