import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let awake = WidgetMetadata(
        title: "Awake",
        systemImage: "cup.and.heat.waves.fill",
        tint: .orange,
        summary: "Keeps your Mac from sleeping",
        details:
            "Stops the Mac sleeping on its own for a while or until you stop it. Closing the lid or choosing Sleep "
            + "still sleeps it, and it's kept awake again on waking. It carries on after Sidelight relaunches."
    )
}

extension AwakeStyle {
    var title: String {
        switch self {
        case .tile: "Tile"
        case .slim: "Slim"
        }
    }

    var widgetStyle: WidgetStyle {
        switch self {
        case .tile:
            WidgetStyle(
                id: rawValue, title: title, summary: "The cup on a disc, ringed by the time left.", family: .modern,
                keywords: ["disc", "ring", "control center", "large"])
        case .slim:
            WidgetStyle(
                id: rawValue, title: title, summary: "One short line over a hairline of time left.", family: .modern,
                keywords: ["minimal", "compact", "small", "line", "thin", "row"])
        }
    }
}

/// One button, like a Control Center tile or a single slim line: the cup, how long the Mac stays awake, and a menu
/// of durations.
struct AwakeWidgetView: View {
    let settings: AwakeSettings
    let layout: WidgetLayout
    @Environment(AwakeSession.self) private var session
    @Environment(\.isWidgetPreview) private var isPreview

    var body: some View {
        AwakeMenu {
            WidgetClock { now in
                label(at: now)
                    .contentShape(.rect)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Keep awake")
                    .accessibilityValue(accessibilityValue(at: now))
                    .accessibilityHint("Shows durations")
                    .help(layout.isGlanceable ? help(at: now) : "")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(isPreview)
    }

    @ViewBuilder
    private func label(at now: Date) -> some View {
        switch settings.style {
        case .tile: tile(at: now)
        case .slim: AwakeSlimLabel(state: session.state, keepsDisplayOn: session.displayHeld, layout: layout, now: now)
        }
    }

    @ViewBuilder
    private func tile(at now: Date) -> some View {
        let state = session.state
        switch layout {
        case .regular:
            HStack(spacing: 10) {
                AwakeDisc(state: state, keepsDisplayOn: session.displayHeld, size: 36, ringWidth: 3, now: now)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.isActive ? "Awake" : "Off").font(.system(size: 13, weight: .semibold))
                    Text(detail(of: state, at: now)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                chevron
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .compact:
            HStack(spacing: 8) {
                AwakeDisc(state: state, keepsDisplayOn: session.displayHeld, size: 28, ringWidth: 2, now: now)
                Text(compactTitle(of: state, at: now)).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                chevron
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .minimal:
            VStack(spacing: 4) {
                AwakeDisc(state: state, keepsDisplayOn: session.displayHeld, size: 32, ringWidth: 2, now: now)
                Text(glance(of: state, at: now)).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        case .bar:
            HStack(spacing: 6) {
                AwakeDisc(state: state, keepsDisplayOn: session.displayHeld, size: 18, ringWidth: 1.5, now: now)
                Text(glance(of: state, at: now)).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
    }

    /// `Sleeps as usual`, `42m left · until 15:42`, `Until you stop`.
    private func detail(of state: AwakeState, at now: Date) -> String {
        switch state {
        case .off: "Sleeps as usual"
        case .indefinite: "Until you stop"
        case .timed(_, let ends):
            "\(state.shortRemaining(at: now) ?? "") left · until \(ends.formatted(date: .omitted, time: .shortened))"
        }
    }

    private func compactTitle(of state: AwakeState, at now: Date) -> String {
        switch state {
        case .off: "Off"
        case .indefinite: "Awake"
        case .timed: "\(state.shortRemaining(at: now) ?? "") left"
        }
    }

    private func glance(of state: AwakeState, at now: Date) -> String {
        switch state {
        case .off: "Off"
        case .indefinite: "∞"
        case .timed: state.shortRemaining(at: now) ?? ""
        }
    }

    private func help(at now: Date) -> String {
        let state = session.state
        return switch state {
        case .off: "The Mac sleeps as usual. Click to keep it awake."
        case .indefinite: "Keeping the Mac awake until you stop it."
        case .timed(_, let ends):
            "Keeping the Mac awake for \(state.shortRemaining(at: now) ?? ""), until "
                + "\(ends.formatted(date: .omitted, time: .shortened))."
        }
    }

    private func accessibilityValue(at now: Date) -> String {
        let state = session.state
        switch state {
        case .off: return "Off"
        case .indefinite: return "On until you stop"
        case .timed:
            let minutes = max(1, ((state.remaining(at: now) ?? 0) / 60).rounded(.up))
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.hour, .minute]
            formatter.unitsStyle = .full
            return "\(formatter.string(from: minutes * 60) ?? "") left"
        }
    }
}

/// The cup on a round disc: grey while the Mac sleeps as usual, orange while it's kept awake, with a ring that runs
/// down over a timed session and a sun while the display stays on too.
private struct AwakeDisc: View {
    let state: AwakeState
    let keepsDisplayOn: Bool
    let size: CGFloat
    let ringWidth: CGFloat
    let now: Date
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        // The disc always leaves room for the ring, so it doesn't shrink as a timed session starts.
        let inset = ringWidth + 1.5
        ZStack {
            Circle()
                .fill(state.isActive ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.primary.opacity(0.08)))
                .padding(inset)
            Image(systemName: state.isActive ? "cup.and.heat.waves.fill" : "cup.and.saucer")
                .font(.system(size: (size - 2 * inset) * 0.45, weight: .medium))
                .foregroundStyle(state.isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
            if let progress = state.progress(at: now) {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(ringWidth / 2)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if state.isActive && keepsDisplayOn {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: size * 0.24, weight: .bold))
                    .foregroundStyle(.yellow)
                    .padding(size * 0.05)
                    .background(Circle().fill(.black.opacity(0.6)))
            }
        }
        .animation(reducesMotion ? nil : Motion.gentle, value: state.progress(at: now))
        .animation(reducesMotion ? nil : Motion.snappy, value: state.isActive)
    }
}

/// One line that always reads Awake, lit while the Mac is kept awake, with the time left at its end and a hairline
/// under it that runs down over a timed session. It keeps its height whatever the state, so the panel never shifts.
private struct AwakeSlimLabel: View {
    let state: AwakeState
    let keepsDisplayOn: Bool
    let layout: WidgetLayout
    let now: Date
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        content
            .animation(reducesMotion ? nil : Motion.gentle, value: state.progress(at: now))
            .animation(reducesMotion ? nil : Motion.snappy, value: state.isActive)
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .regular:
            VStack(spacing: 7) {
                row(detail, glyph: 12, title: 12.5, value: 11.5)
                AwakeHairline(fill: fill)
            }
        case .compact:
            VStack(spacing: 6) {
                row(glance, glyph: 11, title: 11.5, value: 11)
                AwakeHairline(fill: fill)
            }
        case .minimal:
            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    AwakeGlyph(isActive: state.isActive, size: 10.5)
                    valueText(glance, size: 11, weight: .semibold).foregroundStyle(valueStyle)
                }
                AwakeHairline(fill: fill).padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity)
        case .bar:
            HStack(spacing: 5) {
                AwakeGlyph(isActive: state.isActive, size: 11)
                valueText(glance, size: 11.5, weight: .medium).foregroundStyle(valueStyle)
            }
        }
    }

    private func row(_ text: String, glyph: CGFloat, title: CGFloat, value: CGFloat) -> some View {
        HStack(spacing: 6) {
            AwakeGlyph(isActive: state.isActive, size: glyph)
            Text("Awake")
                .font(.system(size: title, weight: .semibold))
                .foregroundStyle(state.isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            if state.isActive && keepsDisplayOn {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: glyph * 0.75, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer(minLength: 6)
            valueText(text, size: value, weight: .medium).foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }

    private func valueText(_ text: String, size: CGFloat, weight: Font.Weight) -> some View {
        Text(text)
            .font(.system(size: size, weight: weight).monospacedDigit())
            .lineLimit(1)
            .contentTransition(.numericText(countsDown: true))
    }

    /// The glance alone names the state, so it dims while off, as the title does in wider cards.
    private var valueStyle: HierarchicalShapeStyle { state.isActive ? .primary : .secondary }

    /// How much of the hairline is lit: all of it until stopped, the share left of a timed session, none when off.
    private var fill: Double {
        switch state {
        case .off: 0
        case .indefinite: 1
        case .timed: state.progress(at: now) ?? 0
        }
    }

    /// `Off`, `∞`, `42m · 15:42`.
    private var detail: String {
        switch state {
        case .off, .indefinite: glance
        case .timed(_, let ends): "\(glance) · \(ends.formatted(date: .omitted, time: .shortened))"
        }
    }

    /// `Off`, `∞`, `42m`.
    private var glance: String {
        switch state {
        case .off: "Off"
        case .indefinite: "∞"
        case .timed: state.shortRemaining(at: now) ?? ""
        }
    }
}

/// The cup, glowing orange while the Mac is kept awake and a grey saucer while it sleeps as usual.
private struct AwakeGlyph: View {
    let isActive: Bool
    let size: CGFloat

    var body: some View {
        Image(systemName: isActive ? "cup.and.heat.waves.fill" : "cup.and.saucer")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(isActive ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .shadow(color: isActive ? .orange.opacity(0.55) : .clear, radius: 3)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: size * 1.3)
    }
}

/// A 2-point track lit from the leading edge by `fill`, between 0 and 1.
private struct AwakeHairline: View {
    let fill: Double

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.08))
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.orange.opacity(0.55), .orange], startPoint: .leading, endPoint: .trailing)
                    )
                    .scaleEffect(x: fill, anchor: .leading)
            }
            .frame(height: 2)
            .accessibilityHidden(true)
    }
}

/// The durations to keep the Mac awake for, how long it's kept now, and whether the display stays on too.
/// A native menu, as the panel never becomes key and so can't hold a popover's controls.
private struct AwakeMenu<Label: View>: View {
    @ViewBuilder let label: Label
    @Environment(AwakeSession.self) private var session
    @Environment(ConfigurationStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Menu {
            switch session.state {
            case .off: EmptyView()
            case .indefinite: Text("Awake Until You Stop")
            case .timed(_, let ends): Text("Awake Until \(ends.formatted(date: .omitted, time: .shortened))")
            }
            if session.state.isActive { Divider() }
            // Picking one starts a fresh session from now, so nothing is checked.
            ForEach(AwakeChoice.presets, id: \.self) { choice in
                Button(choice.title) { session.start(choice) }
            }
            if session.state.isActive {
                Divider()
                Button("Stop") { session.stop() }
            }
            Divider()
            Toggle("Keep Display On", isOn: $store.configuration.awake.keepsDisplayOn)
        } label: {
            label
        }
    }
}

// MARK: - Settings

struct AwakeSettingsEditor: View {
    @Environment(ConfigurationStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Toggle(isOn: $store.configuration.awake.keepsDisplayOn) {
            InfoLabel(
                "Keep display on",
                info: "Every Awake widget shares this. Off lets the screen dim and lock as usual while the Mac stays "
                    + "awake. Closing the lid or choosing Sleep still sleeps the Mac, and while Sidelight is quit "
                    + "it sleeps as usual.")
        }
    }
}
