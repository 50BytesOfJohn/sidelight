import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let agentSessions = WidgetMetadata(
        title: "Agent sessions",
        systemImage: "sparkles.rectangle.stack",
        tint: .indigo,
        summary: "Every agent's sessions in one list",
        details: "Codex and Claude Code sessions, recent Cursor chats and OpenCode sessions, most urgent first. "
            + "Click a Codex or Claude Code session to open it, or a Cursor chat to open its project. Right-click "
            + "an OpenCode session to copy its ID or folder.",
        isBeta: true
    )
}

extension AgentSessionsSettings {
    var summary: String {
        let agents =
            providers.count == AgentProvider.allCases.count
            ? "All agents" : providers.isEmpty ? "No agents" : providers.map(\.title).joined(separator: ", ")
        return "\(agents) · \(sessionCount == 1 ? "1 session" : "\(sessionCount) sessions") · last \(recentHours)h"
    }
}

extension AgentProvider {
    var title: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        case .openCode: "OpenCode"
        }
    }

    /// Why its sessions show when they last changed, for agents that keep no live status.
    var untrackedReason: String? {
        switch self {
        case .cursor: "Cursor doesn't record whether a chat is working or waiting"
        case .openCode: "OpenCode's session list doesn't say whether a session is working or waiting"
        case .codex, .claudeCode: nil
        }
    }
}

extension AgentSession.Status: SessionStatusDisplay {
    var title: String {
        switch self {
        case .needsApproval: "Needs approval"
        case .needsInput: "Needs input"
        case .working: "Working"
        case .finished: "Done"
        case .interrupted: "Interrupted"
        case .idle: "Idle"
        case .closed: "Closed"
        case .unknown: "Status unknown"
        case .untracked: "Updated"
        }
    }

    /// The title, with what's going on: `Needs input · permission prompt`, `Working · auto-review`.
    var detail: String {
        switch self {
        case .needsInput(let reason?) where !reason.isEmpty: "\(title) · \(reason)"
        case .working(let detail?) where !detail.isEmpty: "\(title) · \(detail)"
        default: title
        }
    }

    var color: Color {
        switch self {
        case .needsApproval, .needsInput: .orange
        case .working: .blue
        case .finished: .green
        case .interrupted, .idle, .closed, .unknown, .untracked: .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .needsApproval: "hand.raised.circle.fill"
        case .needsInput: "exclamationmark.circle.fill"
        case .working("auto-review"): "checkmark.shield.fill"
        case .working: "ellipsis.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .interrupted: "pause.circle"
        case .idle: "circle.dashed"
        case .closed: "stop.circle"
        case .unknown: "questionmark.circle"
        case .untracked: "clock"
        }
    }

    var isQuiet: Bool {
        switch self {
        case .needsApproval, .needsInput, .working, .finished: false
        case .interrupted, .idle, .closed, .unknown, .untracked: true
        }
    }

    /// Drawn on the agent's logo: what needs the user, what's working and what just finished.
    var showsBadge: Bool { !isQuiet }
}

extension AgentSession {
    /// Where it runs, in the agent's words: `Claude app`, `Terminal`.
    var surfaceTitle: String {
        switch surface {
        case .terminal: "Terminal"
        case .desktopApp: provider == .codex ? "Codex app" : "Claude app"
        case .editor: "Editor"
        case .background:
            switch provider {
            case .codex: "codex exec"
            case .claudeCode, .cursor, .openCode: "Script or background"
            }
        case .other(let name): name
        }
    }

    var surfaceSystemImage: String {
        switch surface {
        case .terminal: "terminal"
        case .desktopApp: "macwindow"
        case .editor: "chevron.left.forwardslash.chevron.right"
        case .background: "gearshape.2"
        case .other: "square.on.square"
        }
    }

    /// `Needs approval · sidelight · main`.
    var statusLine: String {
        ([status.detail, project, branch].compactMap(\.self)).joined(separator: " · ")
    }

    /// Everything a row says, for VoiceOver and tooltips: `Codex, Release the app, Needs approval, Terminal, 2m`.
    func spokenDescription(now: Date) -> String {
        [provider.title, title, status.detail, project, surfaceTitle, Formatting.shortAge(since: since, now: now)]
            .compactMap(\.self).joined(separator: ", ")
    }
}

// MARK: - Settings

struct AgentSessionsSettingsEditor: View {
    @Binding var settings: AgentSessionsSettings
    @Environment(AgentSessionSources.self) private var sources

    var body: some View {
        ForEach(AgentProvider.allCases) { provider in
            Toggle(isOn: included(provider)) {
                HStack(spacing: 4) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.title)
                            sourceProblem(of: provider)
                        }
                    } icon: {
                        ProviderLogo(provider: provider, size: 16)
                    }
                    if let info = Self.info(about: provider) { InfoButton(info) }
                }
            }
            // One agent at least: an empty card would only say so.
            .disabled(settings.providers == [provider])
            if provider == .codex && settings.includes(.codex) {
                Toggle(isOn: $settings.includesCodexExec) {
                    InfoLabel(
                        "Include codex exec runs",
                        info: "Codex sessions started by scripts and CI. Codex's own session list leaves them out too.")
                }
                .padding(.leading, 24)
            }
        }
        SessionsListedStepper(count: $settings.sessionCount, range: AgentSessionsSettings.sessionCountRange)
        KeepFinishedPicker(
            hours: $settings.recentHours, choices: AgentSessionsSettings.recentHourChoices,
            alsoKept: "So do chats and sessions shown only by when they last changed.")
    }

    /// Where each agent's sessions come from, and what Sidelight can't know about them.
    private static func info(about provider: AgentProvider) -> String? {
        switch provider {
        case .claudeCode:
            "Reads Claude Code's session list in ~/.claude. Nothing to set up, and nothing leaves this Mac."
        case .codex:
            "Reads Codex's session list in ~/.codex. Nothing to set up, and nothing leaves this Mac."
        case .cursor:
            "Reads Cursor's chat list. Cursor doesn't record whether a chat is working or waiting, so chats show "
                + "when they last changed. Clicking a chat opens its project folder in Cursor, since Cursor can't "
                + "open one particular chat."
        case .openCode:
            "Reads OpenCode 2's sessions in ~/.local/share/opencode. OpenCode doesn't record whether a session is "
                + "working or waiting where other apps can read it, so sessions show when they last changed. "
                + "Subagent and archived sessions are left out. Sessions can't be opened from here. Right-click "
                + "one to copy its ID or folder."
        }
    }

    private func included(_ provider: AgentProvider) -> Binding<Bool> {
        Binding {
            settings.includes(provider)
        } set: { isIncluded in
            settings.set(provider, included: isIncluded)
        }
    }

    /// Why an agent's sessions can't be listed, if they can't. Nothing while they can: the list itself shows them.
    @ViewBuilder
    private func sourceProblem(of provider: AgentProvider) -> some View {
        let state = sources.state(of: provider)
        if let problem = state.problem(of: provider) ?? (state == .notFound ? "Not found on this Mac" : nil) {
            StatusRow(color: .orange, dotSize: 6) {
                Text(problem).font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(2)
            .accessibilityElement(children: .combine)
        }
    }
}

extension AgentSessionSources.State {
    /// What keeps an agent's sessions from being listed, or listed up to date, when that isn't a missing agent.
    func problem(of provider: AgentProvider) -> String? {
        switch self {
        case .unsupported where provider == .openCode:
            "This OpenCode keeps its sessions where Sidelight can't read them. Sidelight reads OpenCode 2's database."
        case .unsupported: "This \(provider.title) keeps its sessions where Sidelight can't read them"
        case .unreadable(let isStale):
            "Couldn't read \(provider.title)'s sessions"
                + (isStale ? ", so they may be out of date" : "") + ". Sidelight tries again when they change."
        case .reading, .found, .notFound: nil
        }
    }
}

// MARK: - Widget

struct AgentSessionsWidgetView: View {
    let settings: AgentSessionsSettings
    let layout: WidgetLayout
    @Environment(AgentSessionSources.self) private var sources

    var body: some View {
        let sessions = sources.sessions(for: settings)
        // Ages and the recent window move on with the clock; status changes redraw on their own.
        WidgetClock { now in
            AgentSessionsContent(sources: sources, settings: settings, sessions: sessions, layout: layout, now: now)
        }
        .shimmer(on: latestAlert(in: sessions), cornerRadius: 12)
    }

    /// The newest session to finish or start waiting for you, so the card catches the eye when that happens.
    private func latestAlert(in sessions: [AgentSession]) -> Date? {
        sessions.filter { $0.status == .finished || $0.status.needsUser }.map(\.since).max()
    }
}

/// Every agent's sessions, most urgent first: those waiting for you, those working, those that just finished, then
/// the rest by when they last changed. Each row carries its agent's logo, with what it's doing on it. Minimal and
/// bar layouts count the first three.
private struct AgentSessionsContent: View {
    let sources: AgentSessionSources
    let settings: AgentSessionsSettings
    /// Every session of the widget's agents, before the recent window.
    let sessions: [AgentSession]
    let layout: WidgetLayout
    let now: Date

    private var recent: [AgentSession] {
        sessions.recent(within: settings.recentWindow, now: now)
    }

    private var states: [AgentSessionSources.State] {
        settings.providers.map(sources.state(of:))
    }

    /// What keeps an agent's sessions from being listed, one line each: an agent that's missing isn't a problem.
    private var problems: [String] {
        settings.providers.compactMap { sources.state(of: $0).problem(of: $0) }
    }

    var body: some View {
        let states = states
        let recent = recent
        let problems = problems
        if settings.providers.isEmpty {
            WidgetMessage(
                title: "No agents chosen", detail: "Choose the agents to list in this widget's settings.",
                systemImage: "sparkles.rectangle.stack", layout: layout)
        } else if states.allSatisfy({ $0 == .notFound }) {
            WidgetMessage(
                title: "No agents found",
                detail: "Sessions show here once \(Self.names(settings.providers)) runs on this Mac.",
                systemImage: "terminal", layout: layout)
        } else if recent.isEmpty, states.contains(.reading) {
            // Another agent's empty list isn't the answer while one is still being read.
            WidgetMessage(title: "Reading sessions…", detail: nil, systemImage: "hourglass", layout: layout)
        } else if recent.isEmpty, !problems.isEmpty, !states.contains(where: \.isReadable) {
            // Nothing could be read: an empty list would pass for no sessions.
            WidgetMessage(
                title: "Can't read sessions", detail: problems.joined(separator: "\n"),
                systemImage: "exclamationmark.triangle", layout: layout)
        } else {
            switch layout {
            case .regular:
                AgentSessionList(
                    sessions: recent, limit: settings.sessionCount, settings: settings, now: now, problems: problems)
            case .compact:
                AgentSessionList(
                    sessions: recent, limit: min(settings.sessionCount, 4), settings: settings, now: now,
                    problems: problems, isCompact: true)
            case .minimal, .bar:
                AgentSessionsGlance(sessions: recent, problems: problems, isBar: layout == .bar, now: now)
            }
        }
    }

    /// `Codex, Claude Code or Cursor`.
    static func names(_ providers: [AgentProvider]) -> String {
        let titles = providers.map(\.title)
        guard let last = titles.last, titles.count > 1 else { return titles.first ?? "an agent" }
        return titles.dropLast().joined(separator: ", ") + " or " + last
    }
}

extension AgentSessionSources.State {
    /// Sessions were read, or are being read: what's listed is what there is.
    fileprivate var isReadable: Bool {
        switch self {
        case .reading, .found: true
        case .notFound, .unsupported, .unreadable: false
        }
    }
}

// MARK: - List

private struct AgentSessionList: View {
    let sessions: [AgentSession]
    let limit: Int
    let settings: AgentSessionsSettings
    let now: Date
    /// Agents whose sessions couldn't be read, so the list may be missing some.
    let problems: [String]
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 5 : 8) {
            rows
            ForEach(problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: isCompact ? 9.5 : 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(isCompact ? 1 : 3)
                    .help(problem)
            }
        }
    }

    private var rows: some View {
        SessionList(
            sessions: sessions, limit: limit, isCompact: isCompact,
            emptyText: "No sessions in the last \(settings.recentHours)h", status: \.status
        ) { session in
            AgentSessionRow(session: session, isCompact: isCompact, now: now)
        }
    }
}

private struct AgentSessionRow: View {
    let session: AgentSession
    let isCompact: Bool
    let now: Date

    var body: some View {
        let route = AgentSessionOpener.route(for: session)
        let place = [session.project, session.branch].compactMap(\.self)
        SessionRow(
            title: session.title, status: session.status,
            place: place.isEmpty ? nil : place.joined(separator: " · "),
            surfaceTitle: session.surfaceTitle, surfaceSystemImage: session.surfaceSystemImage,
            since: session.since, isCompact: isCompact, now: now,
            open: route.map { _ in { AgentSessionOpener.open(session) } },
            help: help(route),
            accessibilityLabel: session.spokenDescription(now: now),
            // Sessions that can only be copied from say so, as their tooltip does.
            accessibilityHint: route?.help
                ?? (AgentSessionOpener.contextCopies(of: session).isEmpty
                    ? "" : AgentSessionOpener.unavailableHelp(for: session))
        ) {
            AgentMark(provider: session.provider, status: session.status, size: isCompact ? 13 : 16)
                .padding(.top, isCompact ? 0 : 1)
        } menu: {
            AgentSessionMenu(session: session, route: route)
        }
    }

    private func help(_ route: AgentSessionOpener.Route?) -> String {
        var lines = [session.status.detail]
        if case .needsApproval(let reason?) = session.status, !reason.isEmpty { lines.append(reason) }
        if session.status == .untracked, let reason = session.provider.untrackedReason { lines = [reason] }
        lines.append(route?.help ?? AgentSessionOpener.unavailableHelp(for: session))
        return lines.joined(separator: "\n")
    }
}

/// What a session's right-click offers.
private struct AgentSessionMenu: View {
    let session: AgentSession
    let route: AgentSessionOpener.Route?

    var body: some View {
        if let route {
            Button(route.title, systemImage: route.systemImage) {
                AgentSessionOpener.open(session)
            }
        }
        // When a click brings forward the app running it, the Codex app can still open the session itself.
        if case .codex(let codex) = session.source, route?.kind == .host, CodexSessionOpener.isAppInstalled {
            Button("Open in Codex App", systemImage: "macwindow") { CodexSessionOpener.openInApp(codex) }
        }
        if AgentSessionOpener.canCopyResumeCommand(of: session) {
            Button("Copy Resume Command", systemImage: "doc.on.doc") {
                AgentSessionOpener.copyResumeCommand(of: session)
            }
        }
        ForEach(AgentSessionOpener.contextCopies(of: session)) { context in
            Button(context.title, systemImage: context.systemImage) { AgentSessionOpener.copy(context) }
        }
    }
}

extension AgentSessionOpener.Route {
    var systemImage: String {
        switch kind {
        case .session, .host: "arrow.up.forward.app"
        case .project: "folder"
        }
    }
}

/// An agent's logo with what its session is doing on its corner, cut out of the logo so it reads on any background.
private struct AgentMark: View {
    let provider: AgentProvider
    let status: AgentSession.Status?
    let size: CGFloat

    @Environment(\.colorSchemeContrast) private var contrast

    private var badge: CGFloat { (size * 0.55).rounded() }

    var body: some View {
        let status = status.flatMap { $0.showsBadge ? $0 : nil }
        ProviderLogo(provider: provider, size: size)
            .overlay(alignment: .bottomTrailing) {
                if status != nil {
                    Circle()
                        .frame(width: badge + 3, height: badge + 3)
                        .offset(x: badge * 0.35 + 1.5, y: badge * 0.35 + 1.5)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
            .overlay(alignment: .bottomTrailing) {
                if let status {
                    Image(systemName: status.systemImage)
                        .resizable()
                        .scaledToFit()
                        .fontWeight(contrast == .increased ? .bold : .semibold)
                        .foregroundStyle(status.color)
                        .frame(width: badge, height: badge)
                        .offset(x: badge * 0.35, y: badge * 0.35)
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(Motion.snappy, value: status)
            .accessibilityHidden(true)
    }
}

// MARK: - Glance

/// Minimal and bar: how many sessions need you, are working and are done, across agents.
private struct AgentSessionsGlance: View {
    let sessions: [AgentSession]
    /// Agents whose sessions couldn't be read, so the counts may be missing some.
    let problems: [String]
    let isBar: Bool
    let now: Date

    private var tallies: [SessionTally] {
        [
            SessionTally(AgentSession.Status.needsInput(nil), count: sessions.count { $0.status.needsUser }),
            SessionTally(AgentSession.Status.working(nil), count: sessions.count { $0.status.isWorking }),
            SessionTally(AgentSession.Status.finished, count: sessions.count { $0.status == .finished }),
        ]
        .filter { $0.count > 0 }
    }

    /// What a click does: the most urgent session's route, the session the bar names, so a click never opens
    /// another one. Nothing when that session can't be opened, or would only open a project in its place.
    private var action: (session: AgentSession, route: AgentSessionOpener.Route)? {
        guard let top = sessions.first, let route = AgentSessionOpener.route(for: top),
            route.kind == .session || route.kind == .host
        else { return nil }
        return (top, route)
    }

    private func helpText(_ action: (session: AgentSession, route: AgentSessionOpener.Route)?) -> String {
        var lines =
            sessions.isEmpty
            ? ["No agent sessions"]
            : sessions.prefix(8).map { "\($0.provider.title) · \($0.title): \($0.status.detail)" }
        lines += problems
        if let action { lines.append("Click: \(action.route.title), for \(action.session.title)") }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        let action = action
        let helpText = helpText(action)
        Group {
            if isBar { bar } else { minimal }
        }
        .contentShape(.rect)
        .onTapGesture { if let action { AgentSessionOpener.open(action.session) } }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(helpText)
        .accessibilityAddTraits(action == nil ? [] : .isButton)
        .accessibilityHint(action.map { "\($0.route.help), for \($0.session.title)" } ?? "")
    }

    private var minimal: some View {
        SessionTallyBadge(top: tallies.first, emptySystemImage: "sparkles.rectangle.stack")
    }

    private var bar: some View {
        let tallies = tallies
        return HStack(spacing: 8) {
            SessionTallyCounts(tallies: tallies, emptySystemImage: "sparkles.rectangle.stack")
            if !problems.isEmpty {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
            if let top = sessions.first {
                HStack(spacing: 4) {
                    ProviderLogo(provider: top.provider, size: 11)
                    Text(top.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 160, alignment: .leading)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .animation(Motion.snappy, value: tallies.map(\.count))
    }
}
