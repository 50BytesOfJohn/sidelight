import AppKit
import SidelightCore
import SwiftUI

extension DockerCondition {
    var title: String {
        switch self {
        case .healthy: "Healthy"
        case .running: "Running"
        case .starting: "Starting"
        case .unhealthy: "Unhealthy"
        case .restarting: "Restarting"
        case .paused: "Paused"
        case .created: "Created"
        case .exited(let code): "Exited (\(code))"
        case .crashed(let code): "Crashed (\(code))"
        case .dead: "Dead"
        case .removing: "Removing"
        case .other(let status): status.capitalized
        }
    }

    var color: Color {
        switch self {
        case .healthy, .running: .green
        case .starting: .blue
        case .unhealthy, .restarting, .crashed: .orange
        case .dead: .red
        case .paused, .created, .exited, .removing, .other: .secondary
        }
    }

    /// Its title and how long it's been so: `Healthy · 2h`, `Exited (1) · 3m ago`, `Restarting ×3`.
    func status(of container: DockerContainer, now: Date) -> String {
        switch self {
        case .restarting:
            return container.restartCount > 0 ? "Restarting ×\(container.restartCount)" : title
        case .healthy, .running, .starting, .unhealthy, .paused:
            guard let started = container.startedAt else { return title }
            return "\(title) · \(Formatting.shortAge(since: started, now: now))"
        case .exited, .crashed, .dead:
            guard let finished = container.finishedAt else { return title }
            let age = Formatting.shortAge(since: finished, now: now)
            return "\(title) · \(age == "now" ? "just now" : "\(age) ago")"
        case .created, .removing, .other:
            return title
        }
    }
}

enum DockerFormat {
    /// `0.5% · 62 MiB`; `nil` until stats come in.
    static func usage(_ stats: DockerStats?) -> String? {
        guard let stats else { return nil }
        let cpu = stats.cpuPercent.map { String(format: $0 < 10 ? "%.1f%%" : "%.0f%%", $0) }
        let memory = stats.memoryBytes.map(memory)
        let parts = [cpu, memory].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `62 MiB`, `1.4 GiB`, as Docker counts memory.
    static func memory(_ bytes: Int64) -> String {
        let mebibytes = Double(bytes) / 1_048_576
        if mebibytes >= 1024 { return String(format: "%.1f GiB", mebibytes / 1024) }
        if mebibytes >= 10 { return String(format: "%.0f MiB", mebibytes) }
        return String(format: "%.1f MiB", mebibytes)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A dot in the condition's color.
struct DockerConditionDot: View {
    let condition: DockerCondition
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(condition.color)
            .frame(width: size, height: size)
            .opacity(condition == .starting ? 0.7 : 1)
            .animation(Motion.snappy, value: condition)
            .accessibilityHidden(true)
    }
}

/// `6 running · 1 unhealthy`, the issue part in orange, with the context's name trailing when it helps.
struct DockerHeadline: View {
    let summary: DockerSummary
    var contextName: String?
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 4) {
            Text(summary.running == 0 ? "None running" : "\(summary.running) running")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(summary.running)))
            if let issues = summary.issueText {
                Text("· \(issues)").foregroundStyle(.orange)
            }
            Spacer(minLength: 4)
            if let contextName {
                Text(contextName).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.system(size: size, weight: .medium))
        .lineLimit(1)
        .animation(Motion.snappy, value: summary)
        .accessibilityElement(children: .combine)
    }
}

/// Published ports as small chips: a click opens `http://localhost:PORT`, the menu copies it.
struct DockerPortChips: View {
    let ports: [DockerPort]
    var limit = 4
    /// Previews show the ports but open nothing.
    var isEnabled = true
    var size: CGFloat = 10

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ports.prefix(limit), id: \.self) { port in
                chip(port)
            }
            if ports.count > limit {
                Text("+\(ports.count - limit)")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chip(_ port: DockerPort) -> some View {
        let opens = isEnabled && port.browserURL != nil
        return Button {
            if let url = port.browserURL { NSWorkspace.shared.open(url) }
        } label: {
            Text(port.label)
                .font(.system(size: size, weight: .medium, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .foregroundStyle(opens ? .primary : .secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!opens)
        .help(opens ? "Open localhost:\(port.hostPort) in your browser" : "\(port.transport.uppercased()) port")
        .contextMenu {
            Button("Copy localhost:\(port.hostPort)", systemImage: "doc.on.doc") {
                DockerFormat.copy("localhost:\(port.hostPort)")
            }
        }
        .accessibilityLabel("Port \(port.hostPort)")
    }
}

/// What can be done with a container: copy its name, ID or a command to follow its logs, open its ports.
struct DockerContainerMenu: View {
    let container: DockerContainer
    var opensPorts = true

    var body: some View {
        Button("Copy Name", systemImage: "doc.on.doc") { DockerFormat.copy(container.name) }
        Button("Copy ID", systemImage: "number") { DockerFormat.copy(container.id) }
        Button("Copy “docker logs -f \(container.name)”", systemImage: "terminal") {
            DockerFormat.copy("docker logs -f \(container.name)")
        }
        let urls = container.ports.compactMap { port in port.browserURL.map { (port.hostPort, $0) } }
        if opensPorts, !urls.isEmpty {
            Divider()
            ForEach(urls, id: \.0) { port, url in
                Button("Open localhost:\(port)", systemImage: "safari") { NSWorkspace.shared.open(url) }
            }
        }
    }
}

/// One Compose project, or the containers outside any, in the regular layout: its worst state, how many run, then its
/// issues or else its ports.
struct DockerGroupRow: View {
    let group: DockerGroup
    var opensPorts = true
    let open: (() -> Void)?

    var body: some View {
        Button {
            open?()
        } label: {
            content.contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(open == nil)
        .hoverHighlight(isEnabled: open != nil, vertical: 3)
        .opacity(group.isActive ? 1 : 0.55)
        .help(open == nil ? "Opens from the panel" : "See every container in place of the panel")
    }

    /// A standalone container goes by its own name.
    private var title: String {
        if group.project == nil, group.containers.count == 1, let only = group.containers.first {
            return only.displayName
        }
        return group.title
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                DockerConditionDot(condition: group.worst)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(group.runningCount)/\(group.containers.count)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            let issues = group.issues
            if !issues.isEmpty {
                Text(
                    issues.map { "\($0.displayName) \(group.condition(of: $0).issueTitle ?? "")" }
                        .joined(separator: ", ")
                )
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .padding(.leading, 13)
            } else if !group.ports.isEmpty {
                DockerPortChips(ports: group.ports, isEnabled: opensPorts)
                    .padding(.leading, 13)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One container in the details panel: its state, image and age; ports and usage while it runs; and everything else
/// once expanded.
struct DockerContainerRow: View {
    let container: DockerContainer
    let condition: DockerCondition
    let stats: DockerStats?
    let isExpanded: Bool
    let now: Date
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(action: toggle) {
                summary.contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hides the details" : "Shows the details")
            if condition.isRunning, !container.ports.isEmpty || DockerFormat.usage(stats) != nil {
                HStack(spacing: 6) {
                    DockerPortChips(ports: container.ports, limit: 6)
                    Spacer(minLength: 4)
                    if let usage = DockerFormat.usage(stats) {
                        Text(usage)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 13)
            }
            if isExpanded {
                details
                    .padding(.leading, 13)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
        .hoverHighlight(vertical: 1)
        .contextMenu { DockerContainerMenu(container: container) }
    }

    private var summary: some View {
        HStack(spacing: 6) {
            DockerConditionDot(condition: condition)
            Text(container.displayName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(condition.isActive ? .primary : .secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Text(container.image)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(condition.status(of: container, now: now))
                .font(.system(size: 11))
                .foregroundStyle(condition.isIssue ? condition.color : .secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            line("ID", container.shortID)
            if container.service != nil { line("Container", container.name) }
            line("Image", container.image)
            if let started = container.startedAt {
                line("Started", started.formatted(date: .abbreviated, time: .shortened))
            }
            if container.restartCount > 0 { line("Restarts", "\(container.restartCount)") }
            if !condition.isRunning, container.state != .created {
                line(
                    "Exit code", container.oomKilled ? "\(container.exitCode), out of memory" : "\(container.exitCode)")
            }
            line("Health", health)
        }
        .font(.system(size: 11))
        .textSelection(.enabled)
    }

    private var health: String {
        switch container.health {
        case .none: "No healthcheck"
        case .starting: "Starting"
        case .healthy: "Healthy"
        case .unhealthy: "Unhealthy"
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).lineLimit(2)
        }
    }
}
