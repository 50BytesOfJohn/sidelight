import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let claudeSessions = WidgetMetadata(
        title: "Claude Code sessions",
        systemImage: "rectangle.stack",
        tint: .claude,
        summary: "Claude Code sessions and their status",
        details: "Sessions in the terminal, the desktop app and IDEs. Which are working, which need you, and which "
            + "just finished."
    )
}

extension ClaudeSessionsSettings {
    var summary: String {
        "\(sessionCount == 1 ? "1 session" : "\(sessionCount) sessions") · last \(recentHours)h"
    }
}

extension ClaudeSession.Activity: SessionStatusDisplay {
    var title: String {
        switch self {
        case .needsInput: "Needs input"
        case .working: "Working"
        case .finished: "Done"
        case .idle: "Idle"
        case .closed: "Closed"
        case .unknown: "Status unknown"
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
        case .idle, .closed, .unknown: .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .needsInput: "exclamationmark.circle.fill"
        case .working: "ellipsis.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .idle: "circle.dashed"
        case .closed: "stop.circle"
        case .unknown: "questionmark.circle"
        }
    }

    var isQuiet: Bool { [.idle, .closed, .unknown].contains(self) }
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
        SessionsListedStepper(count: $settings.sessionCount, range: ClaudeSessionsSettings.sessionCountRange)
        KeepFinishedPicker(hours: $settings.recentHours, choices: ClaudeSessionsSettings.recentHourChoices)
        StatusRow(color: service.registryExists ? Color.green : .orange, text: statusText) {
            Spacer(minLength: 4)
            InfoButton(
                "Reads the status Claude Code keeps for its sessions list in ~/.claude/sessions, and titles from its "
                    + "transcripts. Nothing to set up. It updates the moment a session changes.")
        }
    }

    private var statusText: String {
        guard service.registryExists else { return "Claude Code's session list not found" }
        let open = service.sessions.count { $0.activity != .closed }
        return open == 1 ? "1 open session" : "\(open) open sessions"
    }
}

// MARK: - Widget

struct ClaudeSessionsWidgetView: View {
    let settings: ClaudeSessionsSettings
    let layout: WidgetLayout
    @Environment(ClaudeSessionsService.self) private var service

    var body: some View {
        // Ages and the recent window move on with the clock; status changes redraw on their own.
        WidgetClock { now in
            ClaudeSessionsView(service: service, settings: settings, layout: layout, now: now)
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
            WidgetMessage(
                title: "Claude Code not found",
                detail: "Sessions show here once a recent Claude Code runs on this Mac.", systemImage: "terminal",
                layout: layout)
        } else if !service.hasLoaded {
            WidgetMessage(title: "Reading sessions…", systemImage: "hourglass", layout: layout)
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

    private func list(limit: Int, isCompact: Bool) -> some View {
        SessionList(
            sessions: sessions, limit: limit, isCompact: isCompact,
            emptyText: "No sessions in the last \(settings.recentHours)h", status: \.activity
        ) { session in
            SessionRow(
                title: session.title, status: session.activity, place: session.project,
                surfaceTitle: session.surface.title, surfaceSystemImage: session.surface.systemImage,
                since: session.since, isCompact: isCompact, now: now,
                open: ClaudeSessionOpener.canOpen(session) ? { ClaudeSessionOpener.open(session) } : nil
            ) {
                SessionStatusIcon(status: session.activity, isCompact: isCompact)
            } menu: {
                if ClaudeSessionOpener.canOpen(session) {
                    Button("Open", systemImage: "arrow.up.forward.app") { ClaudeSessionOpener.open(session) }
                }
                Button("Copy Resume Command", systemImage: "doc.on.doc") {
                    ClaudeSessionOpener.copyResumeCommand(of: session)
                }
            }
        }
    }

    // MARK: Glanceable

    /// Sessions needing input, working and done, leaving out the kinds with none.
    private var tallies: [SessionTally] {
        let sessions = sessions
        return [
            SessionTally(ClaudeSession.Activity.needsInput(nil), count: sessions.count { $0.activity.isNeedsInput }),
            SessionTally(ClaudeSession.Activity.working, count: sessions.count { $0.activity == .working }),
            SessionTally(ClaudeSession.Activity.finished, count: sessions.count { $0.activity == .finished }),
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
        SessionTallyBadge(top: tallies.first, emptySystemImage: "rectangle.stack")
            .opensMostUrgent(sessions)
            .help(helpText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(helpText)
    }

    private var bar: some View {
        let tallies = tallies
        return HStack(spacing: 8) {
            SessionTallyCounts(tallies: tallies, emptySystemImage: "rectangle.stack")
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
}

extension View {
    fileprivate func opensMostUrgent(_ sessions: [ClaudeSession]) -> some View {
        opensMostUrgent(sessions, canOpen: ClaudeSessionOpener.canOpen, open: ClaudeSessionOpener.open)
    }
}
