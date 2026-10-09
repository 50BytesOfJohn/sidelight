import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let agents = WidgetMetadata(
        title: "Agent activity",
        systemImage: "sparkles",
        tint: .green,
        summary: "\"Agent finished\" events POSTed to 127.0.0.1:\(AgentEventServer.port)/event."
    )
}

struct AgentsSettingsHelp: View {
    var body: some View {
        Text("Send events with scripts/send-event.sh or a Claude Code Stop hook.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

extension AgentEvent.Status {
    var color: Color { self == .finished ? .green : .orange }
    var systemImage: String { self == .finished ? "checkmark.circle.fill" : "bolt.circle.fill" }
}

struct AgentsWidgetView: View {
    let layout: WidgetLayout
    @Environment(AgentEventServer.self) private var server

    private var latestColor: Color { server.latestEvent?.status.color ?? AgentEvent.Status.finished.color }

    var body: some View {
        content.shimmer(on: server.latestEvent?.id, cornerRadius: 12)
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .regular:
            eventList(limit: 10, isCompact: false)
        case .compact:
            eventList(limit: 3, isCompact: true)
        case .minimal:
            icon(size: 20)
                .contentShape(.rect)
                .onTapGesture { server.markAllSeen() }
                .help(server.latestEvent.map { "\($0.source): \($0.message)" } ?? "No agent events")
        case .bar:
            HStack(spacing: 6) {
                icon(size: 15)
                if let event = server.latestEvent {
                    Text(event.summary)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .leading)
                }
            }
            .contentShape(.rect)
            .onTapGesture { server.markAllSeen() }
        }
    }

    /// The sparkles icon with an unread badge tinted by the latest status.
    private func icon(size: CGFloat) -> some View {
        let unread = server.unreadCount
        return Image(systemName: "sparkles")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(unread > 0 ? latestColor : .secondary)
            .frame(width: size + 10, height: size + 8)
            .overlay(alignment: .topTrailing) {
                if unread > 0 {
                    CountBadge(count: unread, color: latestColor)
                        .offset(x: 6, y: -5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(Motion.snappy, value: unread)
    }

    @ViewBuilder
    private func eventList(limit: Int, isCompact: Bool) -> some View {
        if !server.isListening {
            Text("Not listening on :\(String(AgentEventServer.port))").font(.caption).foregroundStyle(.red)
        }
        if server.events.isEmpty {
            Text(isCompact ? "No events yet" : "No events yet · POST 127.0.0.1:\(String(AgentEventServer.port))/event")
                .font(.system(size: isCompact ? 10.5 : 11))
                .foregroundStyle(.secondary)
        }
        // Refresh the relative timestamps.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(alignment: .leading, spacing: isCompact ? 5 : 7) {
                ForEach(server.events.prefix(limit)) { event in
                    EventRow(event: event, isCompact: isCompact)
                        .transition(
                            .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                }
            }
        }
        .animation(Motion.gentle, value: server.events.map(\.id))
    }
}

private struct EventRow: View {
    let event: AgentEvent
    let isCompact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: isCompact ? 6 : 8) {
            Image(systemName: event.status.systemImage)
                .foregroundStyle(event.status.color)
                .font(.system(size: isCompact ? 11 : 14))
            VStack(alignment: .leading, spacing: 1) {
                if !isCompact {
                    Text("\(event.source) · \(event.status.rawValue)").font(.system(size: 11.5, weight: .semibold))
                }
                Text(event.summary)
                    .font(.system(size: isCompact ? 10.5 : 11))
                    .foregroundStyle(isCompact ? .primary : .secondary)
                    .lineLimit(isCompact ? 1 : 2)
            }
            Spacer(minLength: 2)
            Text(event.date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                .font(.system(size: isCompact ? 9 : 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }
}
