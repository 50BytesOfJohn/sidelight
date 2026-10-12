import SidelightCore
import SwiftUI

/// What a session is doing, as the session widgets (Claude Code, Codex and Agent sessions) draw it.
protocol SessionStatusDisplay: Equatable {
    var title: String { get }
    /// The title, with what's going on: `Needs input · permission prompt`.
    var detail: String { get }
    var color: Color { get }
    var systemImage: String { get }
    /// Nothing to act on or watch: drawn quietly.
    var isQuiet: Bool { get }
}

// MARK: - Lists

/// Sessions as rows, at most `limit` of them and how many more there are, animating as they come, go and change.
struct SessionList<Session: Identifiable, Status: Equatable, Row: View>: View {
    let sessions: [Session]
    let limit: Int
    let isCompact: Bool
    /// What a regular list says when there are no sessions; compact ones say "No sessions".
    let emptyText: String
    let status: (Session) -> Status
    @ViewBuilder let row: (Session) -> Row

    var body: some View {
        if sessions.isEmpty {
            Text(isCompact ? "No sessions" : emptyText)
                .font(.system(size: isCompact ? 10.5 : 11))
                .foregroundStyle(.secondary)
        } else {
            let shown = sessions.prefix(limit)
            VStack(alignment: .leading, spacing: isCompact ? 5 : 8) {
                ForEach(shown) { session in
                    row(session)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if sessions.count > limit {
                    Text("\(sessions.count - limit) more")
                        .font(.system(size: isCompact ? 9.5 : 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .animation(Motion.gentle, value: shown.map(\.id))
            .animation(Motion.snappy, value: shown.map(status))
        }
    }
}

/// One session in a list: what it's doing, its title, where it runs and when it last changed, with the status and
/// its place below in the regular layout. A click opens it, when it can be opened; `menu` is its right-click.
struct SessionRow<Status: SessionStatusDisplay, Mark: View, Menu: View>: View {
    let title: String
    let status: Status
    /// What it works on, after the status: `sidelight · main`.
    let place: String?
    let surfaceTitle: String
    let surfaceSystemImage: String
    let since: Date
    let isCompact: Bool
    let now: Date
    /// Opens the session; `nil` when it can't be opened.
    let open: (() -> Void)?
    /// Tooltip; by default, whether a click opens it.
    var help: String?
    /// By default, the title, status, surface and age.
    var accessibilityLabel: String?
    /// By default, whether a click opens it.
    var accessibilityHint: String?
    /// What it's doing, before the title.
    @ViewBuilder let mark: Mark
    @ViewBuilder let menu: Menu

    var body: some View {
        Button {
            open?()
        } label: {
            content.contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight(isEnabled: open != nil, vertical: isCompact ? 2 : 4)
        .contextMenu { menu }
        .help(help ?? (open != nil ? "Open this session" : "Closed. Right-click to copy the command that resumes it."))
        .accessibilityHint(accessibilityHint ?? (open != nil ? "Opens the session" : ""))
    }

    private var content: some View {
        let age = Formatting.shortAge(since: since, now: now)
        return HStack(alignment: isCompact ? .center : .top, spacing: isCompact ? 6 : 8) {
            mark
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: isCompact ? 11 : 12.5, weight: .medium))
                    .foregroundStyle(status.isQuiet ? .secondary : .primary)
                    .lineLimit(1)
                if !isCompact {
                    detail
                }
            }
            Spacer(minLength: 2)
            HStack(spacing: 4) {
                if !isCompact {
                    Image(systemName: surfaceSystemImage)
                        .help(surfaceTitle)
                }
                Text(age)
                    .monospacedDigit()
            }
            .font(.system(size: isCompact ? 9.5 : 10))
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel ?? "\(title), \(status.detail), \(surfaceTitle), \(age)")
    }

    private var detail: some View {
        let status = Text(status.detail)
            .foregroundStyle(status.isQuiet ? Color.secondary : status.color)
        let place = Text(place.map { " · \($0)" } ?? "").foregroundStyle(.secondary)
        return Text("\(status)\(place)")
            .font(.system(size: 11))
            .lineLimit(1)
    }
}

/// The status's symbol in its color, as a row's mark.
struct SessionStatusIcon<Status: SessionStatusDisplay>: View {
    let status: Status
    let isCompact: Bool

    var body: some View {
        Image(systemName: status.systemImage)
            .font(.system(size: isCompact ? 11 : 14))
            .foregroundStyle(status.color)
            .contentTransition(.symbolEffect(.replace))
    }
}

// MARK: - Glanceable

/// How many sessions are doing one thing, as minimal and bar layouts count them.
struct SessionTally: Identifiable {
    let title: String
    let systemImage: String
    let color: Color
    let count: Int
    var id: String { title }

    init(_ status: some SessionStatusDisplay, count: Int) {
        title = status.title
        systemImage = status.systemImage
        color = status.color
        self.count = count
    }
}

/// The first tally's symbol with its count on the corner, or `emptySystemImage` without one: a minimal layout.
struct SessionTallyBadge: View {
    let top: SessionTally?
    let emptySystemImage: String

    var body: some View {
        Image(systemName: top?.systemImage ?? emptySystemImage)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(top?.color ?? .secondary)
            .frame(width: 28, height: 26)
            .overlay(alignment: .topTrailing) {
                if let top {
                    CountBadge(count: top.count, color: top.color)
                        .offset(x: 6, y: -5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(Motion.snappy, value: top?.count)
    }
}

/// Each tally's symbol and count, or `emptySystemImage` without any: how a bar layout starts. Its pieces join the
/// stack it's placed in.
struct SessionTallyCounts: View {
    let tallies: [SessionTally]
    let emptySystemImage: String

    var body: some View {
        if tallies.isEmpty {
            Image(systemName: emptySystemImage).foregroundStyle(.secondary)
        }
        ForEach(tallies) { tally in
            HStack(spacing: 3) {
                Image(systemName: tally.systemImage).foregroundStyle(tally.color)
                Text("\(tally.count)").monospacedDigit().contentTransition(.numericText(value: Double(tally.count)))
            }
        }
    }
}

extension View {
    /// A click opens the first of `sessions` that can be opened: they come most urgent first.
    func opensMostUrgent<Session>(
        _ sessions: [Session], canOpen: (Session) -> Bool, open: @escaping (Session) -> Void
    ) -> some View {
        let target = sessions.first(where: canOpen)
        return contentShape(.rect)
            .onTapGesture { if let target { open(target) } }
            .accessibilityAddTraits(target == nil ? [] : .isButton)
    }
}
