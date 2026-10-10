import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let claudeSessions = WidgetMetadata(
        title: "Claude Code sessions",
        systemImage: "rectangle.stack",
        tint: .claude,
        summary: "Claude Code sessions in the terminal, the desktop app and IDEs: what's working, what needs you, "
            + "what just finished."
    )
}

extension ClaudeSessionsSettings {
    var summary: String {
        "\(sessionCount == 1 ? "1 session" : "\(sessionCount) sessions") · last \(recentHours)h"
    }
}

extension ClaudeSession.Activity {
    var title: String {
        switch self {
        case .needsInput: "Needs input"
        case .working: "Working"
        case .finished: "Done"
        case .idle: "Idle"
        case .closed: "Closed"
        }
    }

    /// The title, with what a waiting session waits for: `Needs input · permission prompt`.
    var detail: String {
        if case .needsInput(let reason?) = self, !reason.isEmpty { return "\(title) · \(reason)" }
        return title
    }

    var color: Color {
        switch self {
        case .needsInput: .orange
        case .working: .blue
        case .finished: .green
        case .idle, .closed: .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .needsInput: "exclamationmark.circle.fill"
        case .working: "ellipsis.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .idle: "circle.dashed"
        case .closed: "stop.circle"
        }
    }
}

extension ClaudeSessionSurface {
    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .desktop: "Claude app"
        case .vscode: "VS Code"
        case .sdk: "Agent SDK"
        case .background: "Background"
        }
    }

    var systemImage: String {
        switch self {
        case .terminal: "terminal"
        case .desktop: "macwindow"
        case .vscode: "chevron.left.forwardslash.chevron.right"
        case .sdk: "gearshape.2"
        case .background: "moon.zzz"
        }
    }
}

// MARK: - Settings

struct ClaudeSessionsSettingsEditor: View {
    @Binding var settings: ClaudeSessionsSettings
    @Environment(ClaudeSessionsService.self) private var service

    var body: some View {
        Stepper(
            "Sessions listed: \(settings.sessionCount)", value: $settings.sessionCount,
            in: ClaudeSessionsSettings.sessionCountRange)
        VStack(alignment: .leading, spacing: 8) {
            Picker("Keep finished for", selection: $settings.recentHours) {
                ForEach(ClaudeSessionsSettings.recentHourChoices, id: \.self) { Text("\($0) h").tag($0) }
            }
            .pickerStyle(.segmented)
            caption(
                "Sessions that are working or need input always show. Finished, idle and closed ones stay this long.")
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(service.registryExists ? Color.green : .orange).frame(width: 7, height: 7)
                Text(statusText).font(.callout)
            }
            caption(
                "Reads the status Claude Code keeps for its own sessions list in ~/.claude/sessions, and titles "
                    + "from its transcripts. Nothing to set up; it updates the moment a session changes."
            )
        }
    }

    private var statusText: String {
        guard service.registryExists else { return "Claude Code's session list not found" }
        let open = service.sessions.count { $0.activity != .closed }
        return open == 1 ? "1 open session" : "\(open) open sessions"
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Widget

struct ClaudeSessionsWidgetView: View {
    let settings: ClaudeSessionsSettings
    let layout: WidgetLayout
    @Environment(ClaudeSessionsService.self) private var service
    @Environment(\.frozenDate) private var frozenDate

    var body: some View {
        Group {
            if let frozenDate {
                ClaudeSessionsView(service: service, settings: settings, layout: layout, now: frozenDate)
            } else {
                // Ages and the recent window move on with the clock; status changes redraw on their own.
                TimelineView(.everyMinute) { context in
                    ClaudeSessionsView(service: service, settings: settings, layout: layout, now: context.date)
                }
            }
        }
        .shimmer(on: latestAlert, cornerRadius: 12)
    }

    /// The newest session to finish or start waiting, so the card catches the eye when that happens.
    private var latestAlert: Date? {
        service.sessions.filter { $0.activity == .finished || $0.activity.isNeedsInput }.map(\.since).max()
    }
}

extension ClaudeSession.Activity {
    fileprivate var isNeedsInput: Bool {
        if case .needsInput = self { true } else { false }
    }
}

/// Sessions most urgent first: those waiting for you, those working, those that just finished, then idle and closed
/// ones. Minimal and bar layouts count the first three.
private struct ClaudeSessionsView: View {
    let service: ClaudeSessionsService
    let settings: ClaudeSessionsSettings
    let layout: WidgetLayout
    let now: Date

    private var sessions: [ClaudeSession] {
        service.sessions.recent(within: settings.recentWindow, now: now)
    }

    var body: some View {
        if !service.registryExists {
            message(
                "Claude Code not found", detail: "Sessions show here once a recent Claude Code runs on this Mac.",
                systemImage: "terminal")
        } else if !service.hasLoaded {
            message("Reading sessions…", detail: nil, systemImage: "hourglass")
        } else {
            switch layout {
            case .regular: list(limit: settings.sessionCount, isCompact: false)
            case .compact: list(limit: min(settings.sessionCount, 4), isCompact: true)
            case .minimal: minimal
            case .bar: bar
            }
        }
    }

    // MARK: Lists

    @ViewBuilder
    private func list(limit: Int, isCompact: Bool) -> some View {
        let sessions = sessions
        if sessions.isEmpty {
            Text(isCompact ? "No sessions" : "No sessions in the last \(settings.recentHours)h")
                .font(.system(size: isCompact ? 10.5 : 11))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: isCompact ? 5 : 8) {
                ForEach(sessions.prefix(limit)) { session in
                    SessionRow(session: session, isCompact: isCompact, now: now)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if sessions.count > limit {
                    Text("\(sessions.count - limit) more")
                        .font(.system(size: isCompact ? 9.5 : 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .animation(Motion.gentle, value: sessions.prefix(limit).map(\.id))
            .animation(Motion.snappy, value: sessions.prefix(limit).map(\.activity))
        }
    }

    // MARK: Glanceable

    private struct Tally: Identifiable {
        let activity: ClaudeSession.Activity
        let count: Int
        var id: String { activity.title }
    }

    /// Sessions needing input, working and done, leaving out the kinds with none.
    private var tallies: [Tally] {
        let sessions = sessions
        return [
            Tally(activity: .needsInput(nil), count: sessions.count { $0.activity.isNeedsInput }),
            Tally(activity: .working, count: sessions.count { $0.activity == .working }),
            Tally(activity: .finished, count: sessions.count { $0.activity == .finished }),
        ]
        .filter { $0.count > 0 }
    }

    private var helpText: String {
        let sessions = sessions
        guard !sessions.isEmpty else { return "No Claude Code sessions" }
        return sessions.prefix(settings.sessionCount).map { "\($0.title): \($0.activity.detail)" }
            .joined(separator: "\n")
    }

    private var minimal: some View {
        let top = tallies.first
        return Image(systemName: top?.activity.systemImage ?? "rectangle.stack")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(top?.activity.color ?? .secondary)
            .frame(width: 28, height: 26)
            .overlay(alignment: .topTrailing) {
                if let top {
                    CountBadge(count: top.count, color: top.activity.color)
                        .offset(x: 6, y: -5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(Motion.snappy, value: top?.count)
            .opensMostUrgent(sessions)
            .help(helpText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(helpText)
    }

    private var bar: some View {
        HStack(spacing: 8) {
            if tallies.isEmpty {
                Image(systemName: "rectangle.stack").foregroundStyle(.secondary)
            }
            ForEach(tallies) { tally in
                HStack(spacing: 3) {
                    Image(systemName: tally.activity.systemImage).foregroundStyle(tally.activity.color)
                    Text("\(tally.count)").monospacedDigit().contentTransition(.numericText(value: Double(tally.count)))
                }
            }
            if let top = sessions.first {
                Text(top.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 140, alignment: .leading)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .animation(Motion.snappy, value: tallies.map(\.count))
        .opensMostUrgent(sessions)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(helpText)
    }

    // MARK: Messages

    @ViewBuilder
    private func message(_ title: String, detail: String?, systemImage: String) -> some View {
        if layout.isGlanceable {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .help([title, detail].compactMap(\.self).joined(separator: ". "))
                .accessibilityLabel([title, detail].compactMap(\.self).joined(separator: ". "))
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(layout == .compact ? .system(size: 11) : .callout)
                if let detail, layout == .regular {
                    Text(detail).font(.caption).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }
}

extension View {
    /// A click opens the first of `sessions` that can be opened: they come most urgent first.
    fileprivate func opensMostUrgent(_ sessions: [ClaudeSession]) -> some View {
        let target = sessions.first(where: ClaudeSessionOpener.canOpen)
        return contentShape(.rect)
            .onTapGesture { if let target { ClaudeSessionOpener.open(target) } }
            .accessibilityAddTraits(target == nil ? [] : .isButton)
    }
}

private struct SessionRow: View {
    let session: ClaudeSession
    let isCompact: Bool
    let now: Date

    @State private var isHovered = false

    private var isQuiet: Bool { session.activity == .idle || session.activity == .closed }
    private var canOpen: Bool { ClaudeSessionOpener.canOpen(session) }

    var body: some View {
        Button {
            if canOpen { ClaudeSessionOpener.open(session) }
        } label: {
            content.contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.primary.opacity(isHovered && canOpen ? 0.08 : 0))
                .padding(.horizontal, -5)
                .padding(.vertical, isCompact ? -2 : -4)
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .contextMenu {
            if canOpen {
                Button("Open", systemImage: "arrow.up.forward.app") { ClaudeSessionOpener.open(session) }
            }
            Button("Copy Resume Command", systemImage: "doc.on.doc") {
                ClaudeSessionOpener.copyResumeCommand(of: session)
            }
        }
        .help(canOpen ? "Open this session" : "Closed. Right-click to copy the command that resumes it.")
        .accessibilityHint(canOpen ? "Opens the session" : "")
    }

    private var content: some View {
        HStack(alignment: isCompact ? .center : .top, spacing: isCompact ? 6 : 8) {
            Image(systemName: session.activity.systemImage)
                .font(.system(size: isCompact ? 11 : 14))
                .foregroundStyle(session.activity.color)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: isCompact ? 11 : 12.5, weight: .medium))
                    .foregroundStyle(isQuiet ? .secondary : .primary)
                    .lineLimit(1)
                if !isCompact {
                    detail
                }
            }
            Spacer(minLength: 2)
            HStack(spacing: 4) {
                if !isCompact {
                    Image(systemName: session.surface.systemImage)
                        .help(session.surface.title)
                }
                Text(Formatting.shortAge(since: session.since, now: now))
                    .monospacedDigit()
            }
            .font(.system(size: isCompact ? 9.5 : 10))
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(session.title), \(session.activity.detail), \(session.surface.title), "
                + Formatting.shortAge(since: session.since, now: now))
    }

    private var detail: some View {
        let status = Text(session.activity.detail)
            .foregroundStyle(isQuiet ? Color.secondary : session.activity.color)
        let project = Text(session.project.map { " · \($0)" } ?? "").foregroundStyle(.secondary)
        return Text("\(status)\(project)")
            .font(.system(size: 11))
            .lineLimit(1)
    }
}
