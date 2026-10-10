import AppKit
import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let noodleComputer = WidgetMetadata(
        title: "Noodle Computer",
        systemImage: "desktopcomputer",
        tint: .blue,
        summary: "Computers in Noodle Computer, for you and your agents: which are running. Click one to open it.",
        isBeta: true
    )
}

extension NoodleComputerSettings {
    var summary: String {
        computerID == nil ? "All computers" : computerName ?? "One computer"
    }
}

extension NoodleComputer.State {
    var title: String {
        switch self {
        case .running: "Running"
        case .starting: "Starting…"
        case .stopping: "Stopping…"
        case .stopped: "Stopped"
        case .upgrading: "Upgrading…"
        case .needsSetup: "Needs setup"
        case .needsAttention: "Needs attention"
        case .other(let label): label
        }
    }

    var color: Color {
        switch self {
        case .running: .green
        case .starting, .stopping, .upgrading: .blue
        case .needsSetup, .needsAttention: .orange
        case .stopped, .other: .secondary
        }
    }

    var isRunning: Bool { self == .running }
}

/// Noodle's six icon gradients, in the order its palette indexes them.
private let noodleIconGradients: [[Color]] = [
    [.blue, .cyan], [.purple, .pink], [.orange, .yellow], [.mint, .teal], [.indigo, .blue], [.pink, .orange],
]

/// A computer's icon the way Noodle Computer draws it: the person's picture, or its symbol on a gradient circle.
private struct ComputerIcon: View {
    let computer: NoodleComputer
    let size: CGFloat

    var body: some View {
        Group {
            if let data = computer.icon, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                // Noodle pins an index outside its palette to the nearest end.
                let colors = noodleIconGradients[min(max(computer.colour, 0), noodleIconGradients.count - 1)]
                Circle()
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        Image(systemName: computer.symbol)
                            .font(.system(size: size * 0.46, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .saturation(computer.state.isRunning || computer.state.isChanging ? 1 : 0.35)
        .opacity(computer.state.isRunning || computer.state.isChanging ? 1 : 0.75)
        .animation(Motion.gentle, value: computer.state)
        .accessibilityHidden(true)
    }
}

/// A small dot in the state's color, dimmer while it changes.
private struct StateDot: View {
    let state: NoodleComputer.State
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: size, height: size)
            .opacity(state.isChanging ? 0.7 : 1)
            .animation(Motion.snappy, value: state)
    }
}

// MARK: - Settings

struct NoodleComputerSettingsEditor: View {
    @Binding var settings: NoodleComputerSettings
    @Environment(NoodleComputerService.self) private var service

    var body: some View {
        Picker("Show", selection: selection) {
            Text("All computers").tag(UUID?.none)
            if !choices.isEmpty { Divider() }
            ForEach(choices) { computer in
                Text(computer.name).tag(Optional(computer.id))
            }
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusText).font(.callout)
            }
            HStack {
                if service.status == .connected {
                    Button(service.isLending ? "Waiting for Noodle Computer…" : "Lend a Computer…") {
                        service.lendComputer()
                    }
                    .disabled(service.isLending)
                } else if case .problem = service.status {
                    Button("Try Again") { service.refreshNow() }
                } else if service.status == .notInstalled || service.status == .notRunning {
                    Button(service.status == .notInstalled ? "Get Noodle Computer" : "Open Noodle Computer") {
                        service.openApp()
                    }
                }
            }
            caption(
                "Beta. Turn on Allow agents in Noodle Computer's settings, under Agents. It asks once whether to "
                    + "let Sidelight in, and shows Sidelight only the computers you lend it. Sidelight checks on "
                    + "them every 30 seconds while Noodle Computer is open, and never while it's closed."
            )
            caption(versionText)
        }
    }

    /// Lent computers, and the chosen one even when Noodle Computer can't be asked right now.
    private var choices: [NoodleComputer] {
        var computers = service.computers
        if let id = settings.computerID, !computers.contains(where: { $0.id == id }) {
            computers.append(
                NoodleComputer(id: id, name: settings.computerName ?? "Chosen computer", kind: "", state: .stopped))
        }
        return computers
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { settings.computerID },
            set: { id in
                settings.computerID = id
                settings.computerName = id.flatMap { id in choices.first { $0.id == id }?.name }
            }
        )
    }

    private var statusText: String {
        switch service.status {
        case .notInstalled: "Noodle Computer isn't installed"
        case .notRunning: "Noodle Computer isn't open"
        case .waitingForWidget: "Connects once the widget is added"
        case .connecting: service.mayBeAsking ? "Noodle Computer is asking whether to let Sidelight in" : "Connecting…"
        case .connected:
            service.computers.count == 1 ? "1 computer lent to Sidelight" : "\(service.computers.count) computers lent"
        case .problem(let problem): problem.title
        }
    }

    private var statusColor: Color {
        switch service.status {
        case .connected: .green
        case .connecting, .waitingForWidget: .blue
        case .notInstalled, .notRunning: .secondary
        case .problem: .orange
        }
    }

    private var versionText: String {
        let tested = "Tested with Noodle Computer \(NoodleComputerService.testedVersion)"
        guard let installed = service.installedVersion else { return tested + "." }
        return installed == NoodleComputerService.testedVersion ? tested + "." : tested + "; you have \(installed)."
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension NoodleComputerProblem {
    fileprivate var title: String {
        switch self {
        case .agentsOff: "Allow agents is off in Noodle Computer"
        case .notAllowed: "Sidelight isn't allowed in Noodle Computer"
        case .notLent, .nothingToLend: "No computer was lent"
        case .failed: "Noodle Computer didn't answer"
        }
    }

    fileprivate var detail: String {
        switch self {
        case .agentsOff: "Turn on Allow agents in its settings, under Agents."
        case .notAllowed: "Try again to be asked again, or remove Sidelight in its settings, under Agents."
        case .notLent, .nothingToLend: "Lend Sidelight a computer to show it here."
        case .failed(let message): message
        }
    }
}

// MARK: - Widget

struct NoodleComputerWidgetView: View {
    let settings: NoodleComputerSettings
    let layout: WidgetLayout
    @Environment(NoodleComputerService.self) private var service

    /// The computers this widget shows: all of them, or the chosen one.
    private var computers: [NoodleComputer] {
        guard let id = settings.computerID else { return service.computers }
        return service.computers.filter { $0.id == id }
    }

    var body: some View {
        let computers = computers
        if computers.isEmpty {
            message
        } else if settings.computerID != nil, let computer = computers.first {
            single(computer)
        } else {
            switch layout {
            case .regular: list(computers, isCompact: false)
            case .compact: list(computers, isCompact: true)
            case .minimal: minimal(computers)
            case .bar: bar(computers)
            }
        }
    }

    // MARK: All computers

    private func list(_ computers: [NoodleComputer], isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: isCompact ? 5 : 8) {
            ForEach(computers) { computer in
                ComputerRow(computer: computer, isCompact: isCompact, service: service)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Motion.gentle, value: computers.map(\.id))
    }

    private func minimal(_ computers: [NoodleComputer]) -> some View {
        let running = computers.count { $0.state.isRunning }
        return Image(systemName: "desktopcomputer")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(running > 0 ? Color.green : .secondary)
            .frame(width: 28, height: 26)
            .overlay(alignment: .topTrailing) {
                if running > 0 {
                    CountBadge(count: running, color: .green)
                        .offset(x: 6, y: -5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(Motion.snappy, value: running)
            .opens { service.openApp() }
            .help(summary(of: computers))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary(of: computers))
    }

    private func bar(_ computers: [NoodleComputer]) -> some View {
        let running = computers.filter { $0.state.isRunning }
        return HStack(spacing: 6) {
            Image(systemName: "desktopcomputer").foregroundStyle(running.isEmpty ? Color.secondary : .green)
            Text(running.isEmpty ? "None running" : "\(running.count) running")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(running.count)))
            if let first = running.first {
                Text(running.count == 1 ? first.name : "\(first.name) +\(running.count - 1)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 140, alignment: .leading)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .animation(Motion.snappy, value: running.map(\.id))
        .opens { service.openApp() }
        .help(summary(of: computers))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary(of: computers))
    }

    private func summary(of computers: [NoodleComputer]) -> String {
        computers.map { "\($0.name): \($0.state.title)" }.joined(separator: "\n")
    }

    // MARK: One computer

    @ViewBuilder
    private func single(_ computer: NoodleComputer) -> some View {
        let label = "\(computer.name), \(computer.state.title)"
        switch layout {
        case .regular:
            HStack(alignment: .top, spacing: 12) {
                ComputerIcon(computer: computer, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(computer.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        StateDot(state: computer.state)
                        Text(computer.state.title).foregroundStyle(computer.state.color)
                        if !computer.kind.isEmpty {
                            Text("· \(computer.kind)").foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11))
                    .lineLimit(1)
                    if let description = computer.description {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .computerActions(computer, service: service)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
        case .compact:
            ComputerRow(computer: computer, isCompact: true, service: service)
        case .minimal:
            ComputerIcon(computer: computer, size: 26)
                .overlay(alignment: .bottomTrailing) {
                    StateDot(state: computer.state, size: 8)
                        .overlay(Circle().strokeBorder(.black.opacity(0.3), lineWidth: 0.5))
                        .offset(x: 2, y: 2)
                }
                .computerActions(computer, service: service)
                .help(label)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        case .bar:
            HStack(spacing: 6) {
                ComputerIcon(computer: computer, size: 16)
                Text(computer.name).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
                StateDot(state: computer.state)
            }
            .font(.system(size: 11, weight: .medium))
            .computerActions(computer, service: service)
            .help(label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
        }
    }

    // MARK: Messages

    private struct Message {
        var title: String
        var detail: String?
        var systemImage: String
        var action: (title: String, run: () -> Void)?
    }

    private var currentMessage: Message {
        switch service.status {
        case .notInstalled:
            Message(
                title: "Noodle Computer not installed",
                detail: "Linux, Mac and Windows computers for you and your agents.", systemImage: "desktopcomputer",
                action: ("Get Noodle Computer", service.openApp))
        case .notRunning:
            Message(
                title: "Noodle Computer isn't open", detail: "Its computers show here while it's open.",
                systemImage: "desktopcomputer", action: ("Open Noodle Computer", service.openApp))
        case .waitingForWidget:
            Message(
                title: "Shows your computers once added",
                detail: "Noodle Computer asks once whether to let Sidelight in.", systemImage: "desktopcomputer")
        case .connecting:
            service.mayBeAsking
                ? Message(
                    title: "Check Noodle Computer", detail: "It's asking whether to let Sidelight in.",
                    systemImage: "hand.raised")
                : Message(title: "Connecting…", systemImage: "hourglass")
        case .connected where settings.computerID != nil:
            Message(
                title: "\(settings.computerName ?? "The chosen computer") isn't lent to Sidelight",
                detail: "Lend it again, or choose another in the widget's settings.", systemImage: "desktopcomputer",
                action: ("Lend a Computer…", service.lendComputer))
        case .connected:
            Message(
                title: "No computers lent to Sidelight",
                detail: "Noodle Computer shows Sidelight only the computers you lend it.",
                systemImage: "desktopcomputer", action: ("Lend a Computer…", service.lendComputer))
        case .problem(let problem):
            Message(
                title: problem.title, detail: problem.detail, systemImage: "exclamationmark.triangle",
                action: ("Try Again", service.refreshNow))
        }
    }

    @ViewBuilder
    private var message: some View {
        let message = currentMessage
        let text = [message.title, message.detail].compactMap(\.self).joined(separator: ". ")
        if layout.isGlanceable {
            Image(systemName: message.systemImage)
                .foregroundStyle(.secondary)
                .opens { message.action?.run() }
                .help(text)
                .accessibilityLabel(text)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(message.title).font(layout == .compact ? .system(size: 11) : .callout)
                if let detail = message.detail, layout == .regular {
                    Text(detail).font(.caption).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                if let action = message.action, layout == .regular {
                    Button(action.title, action: action.run)
                        .controlSize(.small)
                        .disabled(service.isLending)
                        .padding(.top, 4)
                }
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .contain)
        }
    }
}

extension View {
    /// A click runs `action`.
    fileprivate func opens(_ action: @escaping () -> Void) -> some View {
        contentShape(.rect)
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }

    /// A click opens the computer; right-click offers the rest.
    fileprivate func computerActions(_ computer: NoodleComputer, service: NoodleComputerService) -> some View {
        opens { service.open(computer) }
            .contextMenu { ComputerMenu(computer: computer, service: service) }
    }
}

private struct ComputerMenu: View {
    let computer: NoodleComputer
    let service: NoodleComputerService

    var body: some View {
        Button(computer.hasDesktop ? "Open Desktop" : "Open Terminal", systemImage: "arrow.up.forward.app") {
            service.open(computer)
        }
        if computer.state.canStart, service.status == .connected {
            Button("Start in Background", systemImage: "play") { service.startInBackground(computer) }
                .disabled(service.startingComputers.contains(computer.id))
        }
        Divider()
        Button("Lend Another Computer…", systemImage: "plus") { service.lendComputer() }
            .disabled(service.status != .connected || service.isLending)
    }
}

private struct ComputerRow: View {
    let computer: NoodleComputer
    let isCompact: Bool
    let service: NoodleComputerService

    @State private var isHovered = false

    private var isQuiet: Bool { !computer.state.isRunning && !computer.state.isChanging }

    var body: some View {
        Button {
            service.open(computer)
        } label: {
            content.contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.primary.opacity(isHovered ? 0.08 : 0))
                .padding(.horizontal, -5)
                .padding(.vertical, isCompact ? -2 : -4)
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .contextMenu { ComputerMenu(computer: computer, service: service) }
        .help(computer.state.canStart ? "Start and open in Noodle Computer" : "Open in Noodle Computer")
        .accessibilityHint("Opens the computer in Noodle Computer")
    }

    private var content: some View {
        HStack(spacing: isCompact ? 6 : 8) {
            ComputerIcon(computer: computer, size: isCompact ? 18 : 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(computer.name)
                    .font(.system(size: isCompact ? 11 : 12.5, weight: .medium))
                    .foregroundStyle(isQuiet ? .secondary : .primary)
                    .lineLimit(1)
                if !isCompact {
                    detail
                }
            }
            Spacer(minLength: 2)
            if isCompact {
                StateDot(state: computer.state, size: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(computer.name), \(computer.state.title), \(computer.kind)")
    }

    private var detail: some View {
        let state = Text(computer.state.title).foregroundStyle(isQuiet ? Color.secondary : computer.state.color)
        let kind = Text(computer.kind.isEmpty ? "" : " · \(computer.kind)").foregroundStyle(.secondary)
        return HStack(spacing: 4) {
            StateDot(state: computer.state, size: 6)
            Text("\(state)\(kind)").lineLimit(1)
        }
        .font(.system(size: 11))
    }
}
