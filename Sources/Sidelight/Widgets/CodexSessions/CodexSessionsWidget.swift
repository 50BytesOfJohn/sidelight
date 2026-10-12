import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let codexSessions = WidgetMetadata(
        title: "Codex sessions",
        systemImage: "rectangle.stack.badge.play",
        tint: .orange,
        summary: "Codex sessions in the terminal, the desktop app and IDEs: what needs your approval, what's working "
            + "and on which step of its plan, what just finished. Built from blocks.",
        isBeta: true
    )
}

extension CodexSessionsSettings {
    var summary: String {
        let shown = blocks.shownBlocks.map(\.title).joined(separator: ", ")
        return "\(shown.isEmpty ? "No blocks" : shown) · last \(recentHours)h"
    }
}

extension CodexSession.Activity: SessionStatusDisplay {
    var title: String {
        switch self {
        case .needsApproval: "Needs approval"
        case .needsInput: "Asked you"
        case .working: "Working"
        case .finished: "Done"
        case .stopped: "Interrupted"
        case .idle: "Idle"
        case .closed: "Closed"
        }
    }

    /// The title, with what's going on: `Working · auto-review`.
    var detail: String {
        if case .working(reviewing: true) = self { return "\(title) · auto-review" }
        return title
    }

    var color: Color {
        switch self {
        case .needsApproval, .needsInput: .orange
        case .working: .blue
        case .finished: .green
        case .stopped, .idle, .closed: .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .needsApproval: "hand.raised.circle.fill"
        case .needsInput: "questionmark.circle.fill"
        case .working(reviewing: true): "checkmark.shield.fill"
        case .working: "ellipsis.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .stopped: "pause.circle"
        case .idle: "circle.dashed"
        case .closed: "stop.circle"
        }
    }

    var isQuiet: Bool {
        switch self {
        case .stopped, .idle, .closed: true
        default: false
        }
    }
}

extension CodexSessionSurface {
    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .desktop: "Codex app"
        case .ide: "Editor"
        case .exec: "codex exec"
        case .other(let name): name
        }
    }

    var systemImage: String {
        switch self {
        case .terminal: "terminal"
        case .desktop: "macwindow"
        case .ide: "chevron.left.forwardslash.chevron.right"
        case .exec: "gearshape.2"
        case .other: "square.on.square"
        }
    }
}

extension CodexSession {
    /// `gpt-6.1-sol · xhigh`.
    var modelTitle: String? {
        guard let model else { return nil }
        return [model, reasoningEffort].compactMap(\.self).joined(separator: " · ")
    }

    /// `sidelight · main`.
    func place(showsBranch: Bool) -> String? {
        let parts = [project, showsBranch ? branch : nil].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Builder

extension CodexSessionsBlock: DescribedBlock {
    var title: String {
        switch self {
        case .spotlight: "Spotlight"
        case .sessions: "Sessions"
        case .limits: "Limits"
        }
    }

    var systemImage: String {
        switch self {
        case .spotlight: "scope"
        case .sessions: "list.bullet.rectangle"
        case .limits: "gauge.with.dots.needle.33percent"
        }
    }

    var blurb: String {
        switch self {
        case .spotlight: "The most urgent session in detail: its plan, context, changes and last message."
        case .sessions: "Sessions most urgent first. Click one to open it."
        case .limits: "Your plan's 5-hour and weekly limits, as Codex last reported them."
        }
    }
}

extension CodexSessionsSettings: BlockBuiltWidget {
    static let presets = [
        BlockPreset<CodexSessionsBlock>(
            id: "focus", title: "Focus", systemImage: "scope",
            summary: "The most urgent session in detail, then the rest", blocks: [.spotlight, .sessions]),
        BlockPreset(
            id: "list", title: "List", systemImage: "list.bullet.rectangle",
            summary: "Just the sessions, one row each", blocks: [.sessions]),
        BlockPreset(
            id: "everything", title: "Everything", systemImage: "square.grid.2x2",
            summary: "Spotlight, sessions and your limits", blocks: [.spotlight, .sessions, .limits]),
    ]

    static func options(for block: CodexSessionsBlock, settings: Binding<CodexSessionsSettings>) -> some View {
        CodexSessionsBlockOptionsEditor(block: block, settings: settings)
    }

    static func widgetOptions(settings: Binding<CodexSessionsSettings>) -> some View {
        CodexSessionsWidgetOptions(settings: settings)
    }
}

/// The Widgets window's settings: a ready-made layout, and the options for the whole widget. Blocks are arranged
/// in the builder.
struct CodexSessionsSettingsEditor: View {
    @Binding var settings: CodexSessionsSettings

    var body: some View {
        BlockPresetPicker(settings: $settings)
        Divider()
        CodexSessionsWidgetOptions(settings: $settings)
    }
}

/// Which sessions are listed, and where they come from.
struct CodexSessionsWidgetOptions: View {
    @Binding var settings: CodexSessionsSettings
    @Environment(CodexSessionsService.self) private var service

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            KeepFinishedPicker(hours: $settings.recentHours, choices: CodexSessionsSettings.recentHourChoices)
            SettingsCaption(
                "Sessions that are working or need you always show. Finished, idle and closed ones stay this long.")
            Toggle("Include codex exec runs", isOn: $settings.includesExec)
            SettingsCaption("Sessions started by scripts and CI. Codex's own session list leaves them out too.")
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            StatusRow(color: service.codexFound ? Color.green : .orange, text: statusText)
            SettingsCaption(
                "Reads what Codex keeps in ~/.codex: its thread index, which sessions a Codex process has open, and "
                    + "each session's log. Nothing to set up; it updates the moment a turn starts or ends.")
        }
    }

    private var statusText: String {
        guard service.codexFound else { return "Codex's sessions not found" }
        let open = service.sessions.count { $0.pid != nil }
        return open == 1 ? "1 open session" : "\(open) open sessions"
    }
}

private struct CodexSessionsBlockOptionsEditor: View {
    let block: CodexSessionsBlock
    @Binding var settings: CodexSessionsSettings

    var body: some View {
        switch block {
        case .spotlight:
            Toggle("Plan", isOn: $settings.blockOptions.spotlight.showsPlan)
            SettingsCaption("The steps Codex planned for the turn and which it's on, when it made a plan.")
            Toggle("Details", isOn: $settings.blockOptions.spotlight.showsDetails)
            SettingsCaption("Context left, files changed, agents working, and the model.")
            Toggle("Last message", isOn: $settings.blockOptions.spotlight.showsLastMessage)
            SettingsCaption("The start of Codex's reply, once a turn is over.")
        case .sessions:
            Stepper(
                "Rows: \(settings.blockOptions.sessions.maximumRows)",
                value: $settings.blockOptions.sessions.maximumRows, in: CodexSessionListOptions.rowCountRange)
            Toggle("Branch", isOn: $settings.blockOptions.sessions.showsBranch)
            SettingsCaption("The git branch each session started on, next to its folder.")
        case .limits:
            Picker("Show", selection: $settings.blockOptions.limits.reading) {
                ForEach(UsageReading.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Weekly limit", isOn: $settings.blockOptions.limits.showsWeeklyLimit)
            SettingsCaption(
                "Codex logs your limits after every turn. They're shown as of the latest one, at no extra cost.")
        }
    }
}

// MARK: - Widget

struct CodexSessionsWidgetView: View {
    let settings: CodexSessionsSettings
    let layout: WidgetLayout
    @Environment(CodexSessionsService.self) private var service

    var body: some View {
        // Ages and the recent window move on with the clock; status changes redraw on their own.
        WidgetClock { now in
            CodexSessionsContent(service: service, settings: settings, layout: layout, now: now)
        }
        .shimmer(on: latestAlert, cornerRadius: 12)
    }

    /// The newest session to finish or start waiting for you, so the card catches the eye when that happens.
    private var latestAlert: Date? {
        service.sessions.filter { $0.activity == .finished || $0.activity.needsUser }.map(\.since).max()
    }
}

private struct CodexSessionsContent: View {
    let service: CodexSessionsService
    let settings: CodexSessionsSettings
    let layout: WidgetLayout
    let now: Date

    private var sessions: [CodexSession] {
        service.sessions.recent(within: settings.recentWindow, now: now)
            .filter { settings.includesExec || !$0.isExec }
    }

    /// The session the spotlight shows: the most urgent, or the latest.
    private var spotlit: CodexSession? {
        settings.blocks.isShown(.spotlight) ? sessions.first : nil
    }

    private var blocks: [CodexSessionsBlock] {
        settings.blocks.shownBlocks.filter { block in
            switch block {
            case .spotlight: spotlit != nil
            // Nothing left to list once the spotlight has the only session.
            case .sessions: spotlit == nil || sessions.count > 1
            case .limits: true
            }
        }
    }

    var body: some View {
        if !service.codexFound {
            WidgetMessage(
                title: "Codex not found", detail: "Sessions show here once Codex runs on this Mac.",
                systemImage: "terminal", layout: layout)
        } else if !service.hasLoaded {
            WidgetMessage(title: "Reading sessions…", detail: nil, systemImage: "hourglass", layout: layout)
        } else {
            switch layout {
            case .regular, .compact: stack
            case .minimal, .bar: CodexSessionsGlance(sessions: sessions, isBar: layout == .bar)
            }
        }
    }

    @ViewBuilder
    private var stack: some View {
        let blocks = blocks
        let isCompact = layout == .compact
        if settings.blocks.shownBlocks.isEmpty {
            WidgetMessage(
                title: "No blocks shown", detail: "Choose blocks in this widget's builder.",
                systemImage: "square.stack.3d.up", layout: layout)
        } else if blocks.isEmpty {
            Text(isCompact ? "No sessions" : "No Codex sessions in the last \(settings.recentHours)h")
                .font(.system(size: isCompact ? 10.5 : 11))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.element) { index, block in
                    if index > 0 {
                        HairlineDivider()
                            .padding(.vertical, isCompact ? 7 : 10)
                    }
                    view(for: block, isCompact: isCompact)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(Motion.layout, value: blocks)
        }
    }

    @ViewBuilder
    private func view(for block: CodexSessionsBlock, isCompact: Bool) -> some View {
        let options = settings.blockOptions
        switch block {
        case .spotlight:
            if let spotlit {
                CodexSpotlightBlock(
                    session: spotlit, options: options.spotlight, showsBranch: options.sessions.showsBranch,
                    isCompact: isCompact, now: now)
            }
        case .sessions:
            CodexSessionListBlock(
                sessions: sessions.filter { $0.id != spotlit?.id }, hasSpotlight: spotlit != nil,
                options: options.sessions, recentHours: settings.recentHours, isCompact: isCompact, now: now)
        case .limits:
            CodexSessionLimitsBlock(
                rateLimits: service.rateLimits, capturedAt: service.rateLimitsCapturedAt, options: options.limits,
                isCompact: isCompact, now: now)
        }
    }
}

// MARK: - Spotlight

private struct CodexSpotlightBlock: View {
    let session: CodexSession
    let options: CodexSpotlightOptions
    let showsBranch: Bool
    let isCompact: Bool
    let now: Date

    private var canOpen: Bool { CodexSessionOpener.canOpen(session) }

    var body: some View {
        Button {
            if canOpen { CodexSessionOpener.open(session) }
        } label: {
            content.contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight(isEnabled: canOpen, cornerRadius: 8, opacity: 0.06, vertical: 5)
        .contextMenu { CodexSessionMenu(session: session) }
        .help(canOpen ? "Open this session" : "Right-click to copy the command that resumes it.")
        .animation(Motion.snappy, value: session.activity)
        .animation(Motion.gentle, value: session.plan)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: isCompact ? 5 : 8) {
            header
            if case .needsApproval(let justification?) = session.activity, !isCompact {
                approval(justification)
            }
            if options.showsPlan, !session.plan.isEmpty, session.activity.isOngoing || !isCompact {
                CodexPlanView(steps: session.plan, isCompact: isCompact, isActive: session.activity.isOngoing)
            }
            if options.showsLastMessage, !session.activity.isOngoing, let message = session.lastMessage {
                Text(message)
                    .font(.system(size: isCompact ? 10.5 : 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(isCompact ? 1 : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if options.showsDetails, !isCompact {
                details
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: session.activity.systemImage)
                .font(.system(size: isCompact ? 13 : 17))
                .foregroundStyle(session.activity.color)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: isCompact ? 15 : 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: isCompact ? 11.5 : 13, weight: .semibold))
                    .lineLimit(isCompact ? 1 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                let status = Text(session.activity.detail).foregroundStyle(session.activity.color)
                let place = Text(session.place(showsBranch: showsBranch).map { " · \($0)" } ?? "")
                    .foregroundStyle(.secondary)
                Text("\(status)\(place)")
                    .font(.system(size: isCompact ? 10 : 11))
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            HStack(spacing: 4) {
                if !isCompact {
                    Image(systemName: session.surface.systemImage).help(session.surface.title)
                }
                Text(Formatting.shortAge(since: session.since, now: now)).monospacedDigit()
            }
            .font(.system(size: isCompact ? 9.5 : 10))
            .foregroundStyle(.tertiary)
        }
    }

    /// What the command waiting for approval is for, in Codex's words.
    private func approval(_ justification: String) -> some View {
        Text(justification)
            .font(.system(size: 11))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.orange.opacity(0.14)))
    }

    @ViewBuilder
    private var details: some View {
        let chips = detailChips
        if !chips.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { ForEach(chips) { $0.label } }
                HStack(spacing: 10) { ForEach(chips.prefix(3)) { $0.label } }
                HStack(spacing: 10) { ForEach(chips.prefix(2)) { $0.label } }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private struct Chip: Identifiable {
        let id: String
        let label: AnyView
    }

    private var detailChips: [Chip] {
        var chips: [Chip] = []
        if let context = session.context {
            let left = context.percentLeft
            chips.append(
                Chip(
                    id: "context",
                    label: AnyView(
                        HStack(spacing: 3) {
                            ContextGauge(percentUsed: 100 - left)
                            Text("\(Int(left.rounded()))% context")
                        }
                        .help("\(Int(left.rounded()))% of the context window left"))))
        }
        if session.changedFileCount > 0 {
            let count = session.changedFileCount
            chips.append(
                Chip(
                    id: "files",
                    label: AnyView(
                        Label(count == 1 ? "1 file" : "\(count) files", systemImage: "doc")
                            .labelStyle(TightLabelStyle()).help("Files this turn changed"))))
        }
        if !session.workingSubagents.isEmpty {
            let names = session.workingSubagents
            chips.append(
                Chip(
                    id: "agents",
                    label: AnyView(
                        Label(names.count == 1 ? "1 agent" : "\(names.count) agents", systemImage: "person.2")
                            .labelStyle(TightLabelStyle())
                            .help("Working for it: \(names.joined(separator: ", "))"))))
        }
        if !session.activity.isOngoing, let duration = session.lastTurnDuration, duration >= 1 {
            chips.append(
                Chip(
                    id: "took",
                    label: AnyView(
                        Label(Self.duration(duration), systemImage: "timer")
                            .labelStyle(TightLabelStyle()).help("How long the last turn took"))))
        }
        if let model = session.modelTitle {
            chips.append(Chip(id: "model", label: AnyView(Text(model).foregroundStyle(.tertiary))))
        }
        return chips
    }

    /// `45s`, `4m`, `1h 12m`.
    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }
}

/// A small ring filled as far as the context window is.
private struct ContextGauge: View {
    let percentUsed: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(max(percentUsed / 100, 0), 1))
                .stroke(Color.usage(percent: percentUsed), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 9, height: 9)
    }
}

/// Codex's plan for the turn: how far along it is, the step it's on, and what's next.
private struct CodexPlanView: View {
    let steps: [CodexPlanStep]
    let isCompact: Bool
    /// The turn is still going, so the step in progress is being worked on.
    let isActive: Bool

    private var done: Int { steps.count { $0.status == .completed } }
    private var current: CodexPlanStep? { steps.first { $0.status == .inProgress } }
    private var next: CodexPlanStep? {
        let start = steps.firstIndex { $0.status == .inProgress }.map { $0 + 1 } ?? 0
        return steps[start...].first { $0.status == .pending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 3 : 5) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        Capsule()
                            .fill(color(for: step))
                            .frame(height: 3)
                    }
                }
                Text("\(done)/\(steps.count)")
                    .font(.system(size: 9.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let current {
                step(current, systemImage: "circle.dotted.circle", style: .primary)
            }
            if !isCompact, let next {
                step(next, systemImage: "circle", style: .tertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Plan: \(done) of \(steps.count) steps done" + (current.map { ". Now: \($0.text)" } ?? ""))
    }

    private func color(for step: CodexPlanStep) -> Color {
        switch step.status {
        case .completed: .green.opacity(0.85)
        case .inProgress: isActive ? .blue : .secondary
        case .pending: .primary.opacity(0.12)
        }
    }

    private func step(_ step: CodexPlanStep, systemImage: String, style: HierarchicalShapeStyle) -> some View {
        Label {
            Text(step.text).lineLimit(1)
        } icon: {
            Image(systemName: systemImage)
        }
        .labelStyle(TightLabelStyle())
        .font(.system(size: isCompact ? 10 : 11))
        .foregroundStyle(style)
    }
}

// MARK: - Sessions

private struct CodexSessionListBlock: View {
    let sessions: [CodexSession]
    let hasSpotlight: Bool
    let options: CodexSessionListOptions
    let recentHours: Int
    let isCompact: Bool
    let now: Date

    private var limit: Int { isCompact ? min(options.maximumRows, 4) : options.maximumRows }

    var body: some View {
        SessionList(
            sessions: sessions, limit: limit, isCompact: isCompact,
            emptyText: "No Codex sessions in the last \(recentHours)h", status: \.activity
        ) { session in
            SessionRow(
                title: session.title, status: session.activity, place: session.place(showsBranch: options.showsBranch),
                surfaceTitle: session.surface.title, surfaceSystemImage: session.surface.systemImage,
                since: session.since, isCompact: isCompact, now: now,
                open: CodexSessionOpener.canOpen(session) ? { CodexSessionOpener.open(session) } : nil
            ) {
                SessionStatusIcon(status: session.activity, isCompact: isCompact)
            } menu: {
                CodexSessionMenu(session: session)
            }
        }
    }
}

/// What a session's right-click offers.
private struct CodexSessionMenu: View {
    let session: CodexSession

    var body: some View {
        if CodexSessionOpener.canOpen(session) {
            Button("Open", systemImage: "arrow.up.forward.app") { CodexSessionOpener.open(session) }
        }
        if session.surface != .desktop, session.pid != nil, CodexSessionOpener.isAppInstalled {
            Button("Open in Codex App", systemImage: "macwindow") { CodexSessionOpener.openInApp(session) }
        }
        Button("Copy Resume Command", systemImage: "doc.on.doc") {
            CodexSessionOpener.copyResumeCommand(of: session)
        }
    }
}

// MARK: - Limits

private struct CodexSessionLimitsBlock: View {
    let rateLimits: CodexRateLimits?
    let capturedAt: Date?
    let options: CodexSessionLimitsOptions
    let isCompact: Bool
    let now: Date

    /// Limits older than this say how old they are.
    private static let staleAfter: TimeInterval = 30 * 60

    var body: some View {
        if let rateLimits, !rateLimits.limits().isEmpty {
            VStack(alignment: .leading, spacing: isCompact ? 4 : 7) {
                ForEach(rateLimits.limits(includesLonger: options.showsWeeklyLimit)) { limit in
                    row(limit)
                }
                if let capturedAt, now.timeIntervalSince(capturedAt) > Self.staleAfter {
                    Text("As of \(UsageFormat.age(of: capturedAt, now: now))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            Text("Limits show after Codex's next turn")
                .font(.system(size: isCompact ? 10.5 : 11))
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ limit: CodexLimit) -> some View {
        let hasReset = limit.hasReset(at: now)
        let used = min(max(limit.window.usedPercent, 0), 100)
        let shown = options.reading == .remaining ? 100 - used : used
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title).font(.system(size: isCompact ? 10 : 11, weight: .medium))
                Spacer(minLength: 4)
                Group {
                    if hasReset {
                        Text("Reset")
                    } else {
                        let resets = Text(limit.window.resetsAt.map { " · \(UsageFormat.moment($0, now: now))" } ?? "")
                            .foregroundStyle(.tertiary)
                        Text("\(Int(shown.rounded()))% \(options.reading.suffix)\(resets)")
                    }
                }
                .font(.system(size: isCompact ? 9.5 : 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            SegmentedMeter(
                percent: hasReset ? 0 : used,
                segments: limit.segments,
                elapsedFraction: hasReset ? nil : limit.window.elapsedFraction(at: now),
                height: isCompact ? 3 : 5,
                spacing: isCompact ? 1.5 : 2.5,
                showsRemaining: !hasReset && options.reading == .remaining
            )
            .opacity(hasReset ? 0.45 : 1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Glance

/// Minimal and bar: how many sessions need you, are working and are done.
private struct CodexSessionsGlance: View {
    let sessions: [CodexSession]
    let isBar: Bool

    private var tallies: [SessionTally] {
        let approvals = sessions.count { if case .needsApproval = $0.activity { true } else { false } }
        return [
            SessionTally(CodexSession.Activity.needsApproval(nil), count: approvals),
            SessionTally(CodexSession.Activity.needsInput, count: sessions.count { $0.activity == .needsInput }),
            SessionTally(
                CodexSession.Activity.working(reviewing: false),
                count: sessions.count { if case .working = $0.activity { true } else { false } }),
            SessionTally(CodexSession.Activity.finished, count: sessions.count { $0.activity == .finished }),
        ]
        .filter { $0.count > 0 }
    }

    private var helpText: String {
        guard !sessions.isEmpty else { return "No Codex sessions" }
        return sessions.prefix(8).map { "\($0.title): \($0.activity.detail)" }.joined(separator: "\n")
    }

    var body: some View {
        Group {
            if isBar { bar } else { minimal }
        }
        .opensMostUrgent(sessions)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(helpText)
    }

    private var minimal: some View {
        SessionTallyBadge(top: tallies.first, emptySystemImage: "rectangle.stack")
    }

    private var bar: some View {
        let tallies = tallies
        return HStack(spacing: 8) {
            SessionTallyCounts(tallies: tallies, emptySystemImage: "rectangle.stack")
            if let top = sessions.first {
                Text(top.plan.first { $0.status == .inProgress }.map { "\(top.title) · \($0.text)" } ?? top.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .animation(Motion.snappy, value: tallies.map(\.count))
    }
}

extension View {
    fileprivate func opensMostUrgent(_ sessions: [CodexSession]) -> some View {
        opensMostUrgent(sessions, canOpen: CodexSessionOpener.canOpen, open: CodexSessionOpener.open)
    }
}
