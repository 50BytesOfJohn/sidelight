import AppKit
import SidelightCore
import SwiftUI
import UniformTypeIdentifiers

struct AppLauncherSettingsEditor: View {
    @Binding var settings: AppLauncherSettings
    @Environment(AppLauncherService.self) private var service
    @Environment(AccessibilityPermission.self) private var accessibility

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
        countPicker("Columns", value: $settings.columns, range: AppLauncherSettings.columnRange, zero: "Fit")
        countPicker("Rows", value: $settings.rows, range: AppLauncherSettings.rowRange, zero: "All")
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
                info: "New Window presses the app's own New Window menu item, which needs Accessibility access. "
                    + "Without it, the menu doesn't offer New Window.")
            StatusRow(
                color: accessibility.isTrusted ? .green : .orange,
                text: accessibility.isTrusted ? "New Window available" : "New Window needs Accessibility access"
            ) {
                if !accessibility.isTrusted {
                    Spacer(minLength: 4)
                    Button("Grant Access…") { accessibility.request() }
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

    /// A menu where 0, "Fit" or "All", comes first: any count is one choice away, and the row never changes size.
    private func countPicker(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, zero: String) -> some View {
        Picker(title, selection: value) {
            Text(zero).tag(0)
            Divider()
            ForEach(range.filter { $0 > 0 }, id: \.self) { count in
                Text("\(count)").tag(count)
            }
        }
    }
}
