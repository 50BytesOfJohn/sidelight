import SidelightCore
import SwiftUI

/// The panel's default position, size and visibility, and each display's own overrides of them.
struct PanelSettingsPane: View {
    @Environment(ConfigurationStore.self) private var store
    @Environment(DisplayMonitor.self) private var monitor
    @State private var selectedDisplayID: Display.ID?

    var body: some View {
        let configuration = store.configuration
        let displays = monitor.displays
        let selected = displays.first { $0.id == selectedDisplayID } ?? displays.first
        let isHiddenEverywhere = !displays.contains { $0.panel(in: configuration).showsPanel }

        Form {
            DefaultsSection(displays: displays)

            Section {
                DisplayArrangementView(
                    displays: displays,
                    configuration: configuration,
                    selection: Binding(get: { selected?.id }, set: { selectedDisplayID = $0 })
                )
                .frame(height: displays.count > 1 ? 210 : 180)
            } header: {
                Text("Displays")
            } footer: {
                if isHiddenEverywhere {
                    Label("The panel is hidden on every connected display.", systemImage: "eye.slash")
                        .foregroundStyle(.orange)
                        .settingsFootnote()
                } else if displays.count > 1 {
                    Text("Click a display to give it its own settings.").settingsFootnote()
                }
            }

            if let selected {
                DisplayOverridesSection(display: selected).id(selected.id)
            }

            RememberedDisplaysSection(connected: displays)
        }
    }
}

/// What every display uses unless it overrides it.
private struct DefaultsSection: View {
    let displays: [Display]
    @Environment(ConfigurationStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let defaults = store.configuration.panel

        Section {
            TilePicker(
                values: PanelPosition.allCases,
                selection: $store.configuration.panel.position.animation(Motion.layout),
                title: \.title
            ) { position, isSelected in
                PositionMiniature(
                    position: position, length: defaults.length, alignment: defaults.alignment,
                    isSelected: isSelected)
            }

            if let reference = displays.first {
                WidthPicker(width: $store.configuration.panel.width, display: reference)
                    .disabled(defaults.position.isBar)
            }

            Picker("Length", selection: $store.configuration.panel.length.animation(Motion.layout)) {
                ForEach(PanelLength.allCases) { length in
                    Text(length.title).tag(length)
                }
            }
            .pickerStyle(.segmented)

            Picker("Alignment", selection: $store.configuration.panel.alignment.animation(Motion.layout)) {
                ForEach(PanelAlignment.allCases) { alignment in
                    Text(alignment.title(for: defaults.position)).tag(alignment)
                }
            }
            .pickerStyle(.segmented)
            .disabled(defaults.length == .fill)

            Picker("Show panel on", selection: $store.configuration.panel.shownOn.animation(Motion.layout)) {
                Text("Main display").tag(PanelDisplays.main)
                Text("All displays").tag(PanelDisplays.all)
            }
            .pickerStyle(.segmented)
        } header: {
            Text(displays.count > 1 ? "All Displays" : "Panel")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if defaults.position.isBar {
                    Text(
                        "Top and bottom bars are \(Int(PanelMetrics.barThickness)) pt tall and show one glanceable value per widget. Width applies to side panels."
                    )
                } else if defaults.width.preset != nil {
                    Text("Presets adapt to each display: a little wider on bigger screens.")
                } else {
                    Text(
                        "Up to half of each display. Wider panels add columns instead of stretching widgets."
                    )
                }
                if defaults.length == .fit {
                    Text(
                        "Fit content makes the panel as long as its widgets. Other windows still keep clear of the whole edge, so they don't move as widgets come and go."
                    )
                }
            }
            .settingsFootnote()
        }
    }
}

/// One display's overrides: each setting follows All Displays until changed here.
private struct DisplayOverridesSection: View {
    let display: Display
    @Environment(ConfigurationStore.self) private var store

    var body: some View {
        let configuration = store.configuration
        let defaults = configuration.panel
        let profile = configuration.displayProfile(id: display.id)
        let panel = display.panel(in: configuration)
        let points = display.panelWidth(panel.width)

        Section {
            Picker("Panel", selection: override(\.showsPanel)) {
                Text("Default (\(defaults.showsPanel(onMainDisplay: display.isMain) ? "Shown" : "Hidden"))")
                    .tag(Bool?.none)
                Divider()
                Text("Show").tag(Bool?.some(true))
                Text("Hide").tag(Bool?.some(false))
            }

            if panel.showsPanel {
                Picker("Position", selection: override(\.position)) {
                    Text("Default (\(defaults.position.title))").tag(PanelPosition?.none)
                    Divider()
                    ForEach(PanelPosition.allCases) { position in
                        Text(position.title).tag(PanelPosition?.some(position))
                    }
                }

                Picker("Width", selection: widthOverride(profile?.width, currentPoints: points)) {
                    Text("Default (\(defaults.width.title))").tag(WidthOverride.useDefault)
                    Divider()
                    ForEach(WidgetDensity.allCases) { density in
                        Text(density.title).tag(WidthOverride.preset(density))
                    }
                    Text("Custom").tag(WidthOverride.custom)
                }
                .disabled(panel.position.isBar)

                if let width = profile?.width, width.preset == nil {
                    CustomWidthEditor(
                        display: display,
                        width: Binding {
                            store.configuration.displayProfile(id: display.id)?.width ?? width
                        } set: { newWidth in
                            update { $0.width = newWidth }
                        }
                    )
                    .disabled(panel.position.isBar)
                }

                Picker("Length", selection: override(\.length)) {
                    Text("Default (\(defaults.length.title))").tag(PanelLength?.none)
                    Divider()
                    ForEach(PanelLength.allCases) { length in
                        Text(length.title).tag(PanelLength?.some(length))
                    }
                }

                Picker("Alignment", selection: override(\.alignment)) {
                    Text("Default (\(defaults.alignment.title(for: panel.position)))").tag(PanelAlignment?.none)
                    Divider()
                    ForEach(PanelAlignment.allCases) { alignment in
                        Text(alignment.title(for: panel.position)).tag(PanelAlignment?.some(alignment))
                    }
                }
                .disabled(panel.length == .fill)

                LabeledContent("Result") {
                    let edge = [panel.position.title + (panel.position.isBar ? " bar" : ""), panel.fitSummary]
                        .compactMap(\.self).joined(separator: " · ")
                    if panel.position.isBar {
                        Text("\(edge) · \(Int(PanelMetrics.barThickness)) pt tall")
                    } else {
                        Text(
                            "\(edge) · \(Int(points)) pt · \(PanelColumns(panelWidth: Double(points)).summary)"
                        )
                        .contentTransition(.numericText())
                        .animation(Motion.snappy, value: points)
                    }
                }
                .foregroundStyle(.secondary)
            }

            if profile != nil {
                HStack {
                    Spacer()
                    Button("Use Defaults") {
                        withAnimation(Motion.layout) { store.configuration.displays.removeAll { $0.id == display.id } }
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            DisplayHeader(display: display)
        } footer: {
            Text("Settings left at Default follow \"All Displays\" above.").settingsFootnote()
        }
    }

    private enum WidthOverride: Hashable {
        case useDefault
        case preset(WidgetDensity)
        case custom
    }

    /// Choosing Custom starts from the current width, so the panel doesn't jump.
    private func widthOverride(_ width: PanelWidth?, currentPoints: CGFloat) -> Binding<WidthOverride> {
        Binding {
            switch width {
            case nil: .useDefault
            case .preset(let density)?: .preset(density)
            case _?: .custom
            }
        } set: { choice in
            withAnimation(Motion.layout) {
                switch choice {
                case .useDefault: update { $0.width = nil }
                case .preset(let density): update { $0.width = .preset(density) }
                case .custom: update { $0.width = .points(Double(currentPoints)) }
                }
            }
        }
    }

    private func override<Value>(_ keyPath: WritableKeyPath<DisplayProfile, Value?>) -> Binding<Value?> {
        Binding {
            store.configuration.displayProfile(id: display.id)?[keyPath: keyPath]
        } set: { value in
            withAnimation(Motion.layout) { update { $0[keyPath: keyPath] = value } }
        }
    }

    private func update(_ change: (inout DisplayProfile) -> Void) {
        store.configuration.updateProfile(of: display, change)
    }
}

/// Preset densities or a custom width, as a segmented control.
private struct WidthPicker: View {
    @Binding var width: PanelWidth
    /// Converts presets to points when switching to Custom, and bounds the custom editor.
    let display: Display

    private enum Choice: Hashable {
        case preset(WidgetDensity)
        case custom
    }

    var body: some View {
        let choice = Binding<Choice> {
            width.preset.map(Choice.preset) ?? .custom
        } set: { choice in
            withAnimation(Motion.layout) {
                switch choice {
                case .preset(let density): width = .preset(density)
                // Start from the current width, so the panel doesn't jump.
                case .custom: width = .points(Double(display.panelWidth(width)))
                }
            }
        }

        Picker("Width", selection: choice) {
            ForEach(WidgetDensity.allCases) { density in
                Text(density.title).tag(Choice.preset(density))
            }
            Text("Custom").tag(Choice.custom)
        }
        .pickerStyle(.segmented)

        if width.preset == nil {
            CustomWidthEditor(display: display, width: $width)
        }
    }
}

/// A slider plus an exact value, in points or percent of the display's width.
private struct CustomWidthEditor: View {
    let display: Display
    @Binding var width: PanelWidth

    private enum Unit: Hashable {
        case points, percent
    }

    var body: some View {
        let screenWidth = Double(display.frame.width)
        let unit: Unit = if case .percent = width { .percent } else { .points }
        let range = unit == .points ? PanelWidth.pointsRange(screenWidth: screenWidth) : PanelWidth.percentRange
        let value = Binding<Double> {
            switch width {
            case .percent(let percent): percent
            default: width.points(screenWidth: screenWidth)
            }
        } set: { newValue in
            let clamped = min(max(newValue.rounded(), range.lowerBound), range.upperBound)
            width = unit == .points ? .points(clamped) : .percent(clamped)
        }
        let unitBinding = Binding<Unit> {
            unit
        } set: { newUnit in
            // Keep the panel the same width; only the way it's expressed changes.
            let points = width.points(screenWidth: screenWidth)
            width = newUnit == .points ? .points(points) : .percent((points / screenWidth * 100).rounded())
        }

        LabeledContent("Custom width") {
            HStack(spacing: 10) {
                Slider(value: value, in: range)
                TextField("Width", value: value, format: .number.precision(.fractionLength(0)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 52)
                Picker("Unit", selection: unitBinding) {
                    Text("pt").tag(Unit.points)
                    Text("%").tag(Unit.percent)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .frame(minWidth: 280)
        }
    }
}

/// Section header naming the display, e.g. "Built-in Retina Display — Main · 1512 × 982 pt".
private struct DisplayHeader: View {
    let display: Display

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: display.systemImage)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(display.name).font(.headline)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var details: String {
        var parts: [String] = []
        if display.isMain { parts.append("Main display") }
        if display.isBuiltIn { parts.append("Built-in") }
        parts.append("\(Int(display.frame.width)) × \(Int(display.frame.height)) pt")
        return parts.joined(separator: " · ")
    }
}

/// Overrides of displays that aren't connected right now, so they can be forgotten.
private struct RememberedDisplaysSection: View {
    let connected: [Display]
    @Environment(ConfigurationStore.self) private var store

    var body: some View {
        let connectedIDs = Set(connected.map(\.id))
        let remembered = store.configuration.displays.filter { !connectedIDs.contains($0.id) }
        if !remembered.isEmpty {
            Section {
                ForEach(remembered) { profile in
                    LabeledContent {
                        Button("Forget") {
                            withAnimation(Motion.layout) {
                                store.configuration.displays.removeAll { $0.id == profile.id }
                            }
                        }
                        .controlSize(.small)
                    } label: {
                        Label {
                            Text(profile.name)
                            Text(profile.overridesSummary(defaults: store.configuration.panel))
                        } icon: {
                            Image(systemName: "display").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Other Displays")
            } footer: {
                Text("Own settings of displays that aren't connected. They apply again when the display is.")
                    .settingsFootnote()
            }
        }
    }
}

extension DisplayProfile {
    /// e.g. `Top · Compact · Fit content · Aligned Right`, or `Panel hidden`. Alignment titles depend on the
    /// position, which may come from `defaults`.
    func overridesSummary(defaults: PanelDefaults) -> String {
        if showsPanel == false { return "Panel hidden" }
        let alignmentTitle = alignment.map { "Aligned \($0.title(for: position ?? defaults.position))" }
        let parts = [showsPanel == true ? "Shown" : nil, position?.title, width?.title, length?.title, alignmentTitle]
        return parts.compactMap(\.self).joined(separator: " · ")
    }
}

extension DisplayPanel {
    /// e.g. `Fit, Middle`, or `nil` when the panel fills its edge.
    var fitSummary: String? {
        length == .fit ? "Fit, \(alignment.title(for: position))" : nil
    }
}

/// A tiny screen with the panel on one edge, fitted and aligned if the defaults say so.
private struct PositionMiniature: View {
    let position: PanelPosition
    let length: PanelLength
    let alignment: PanelAlignment
    let isSelected: Bool

    var body: some View {
        let size = CGSize(width: 76, height: 48)
        let thickness: CGFloat = position.isBar ? 7 : 15
        let strip = PanelMetrics.frame(
            position: position, thickness: thickness, in: CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3))
        let panel = PanelMetrics.previewFrame(inStrip: strip, position: position, length: length, alignment: alignment)
        ZStack(alignment: .topLeading) {
            PreviewStage()
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(isSelected ? Color.accentColor : .white.opacity(0.75))
                .frame(width: panel.width, height: panel.height)
                // Cocoa rects grow upwards; SwiftUI offsets grow downwards.
                .offset(x: panel.minX, y: size.height - panel.maxY)
        }
        .frame(width: size.width, height: size.height)
    }
}

extension View {
    /// Secondary explanatory text under a settings section.
    func settingsFootnote() -> some View {
        font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
