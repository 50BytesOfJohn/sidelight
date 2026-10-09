import SwiftUI

enum AgentWidget: PanelWidget {
    static let meta = WidgetMeta(kind: "agents", title: "Agent activity", icon: "sparkles", tint: .green,
                                 summary: "\"Agent finished\" events POSTed to 127.0.0.1:47821/event.")

    static func content(_ ctx: WidgetContext) -> some View { AgentView(m: ctx.models.agents, ctx: ctx) }

    static func settings(_ s: Binding<WidgetSettings>) -> some View {
        Text("Send events with scripts/send-event.sh or a Claude Code Stop hook.").font(.callout).foregroundStyle(.secondary)
    }
}

private struct AgentView: View {
    @ObservedObject var m: AgentServer
    let ctx: WidgetContext

    var latestColor: Color { (m.events.first?.status ?? "finished") == "finished" ? .green : .orange }

    var body: some View {
        Group {
            if ctx.bar {
                HStack(spacing: 6) {
                    icon(15)
                    if let e = m.events.first {
                        Text(e.message.isEmpty ? e.status : e.message).font(.system(size: 11)).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
                    }
                }
                .contentShape(Rectangle()).onTapGesture { m.markSeen() }
            } else {
                switch ctx.size {
                case .minimal:
                    icon(20).contentShape(Rectangle()).onTapGesture { m.markSeen() }
                        .help(m.events.first.map { "\($0.source): \($0.message)" } ?? "No agent events")
                case .compact: list(limit: 3, compact: true)
                case .regular: list(limit: 10, compact: false)
                }
            }
        }
        .modifier(Shimmer(trigger: m.events.first?.id, radius: 12))
    }

    /// icon with unread badge colored by latest status
    func icon(_ size: CGFloat) -> some View {
        Image(systemName: "sparkles").font(.system(size: size, weight: .medium))
            .foregroundStyle(m.unread > 0 ? latestColor : .secondary)
            .frame(width: size + 10, height: size + 8)
            .overlay(alignment: .topTrailing) {
                if m.unread > 0 { Badge(count: m.unread, color: latestColor).offset(x: 6, y: -5).transition(.scale.combined(with: .opacity)) }
            }
            .animation(Theme.snappy, value: m.unread)
    }

    @ViewBuilder func list(limit: Int, compact: Bool) -> some View {
        if !m.listening { Text("Not listening on :47821").font(.caption).foregroundStyle(.red) }
        if m.events.isEmpty {
            Text(compact ? "No events yet" : "No events yet · POST 127.0.0.1:47821/event").font(.system(size: compact ? 10.5 : 11)).foregroundStyle(.secondary)
        }
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(alignment: .leading, spacing: compact ? 5 : 7) {
                ForEach(m.events.prefix(limit)) { e in
                    HStack(alignment: .top, spacing: compact ? 6 : 8) {
                        Image(systemName: e.status == "finished" ? "checkmark.circle.fill" : "bolt.circle.fill")
                            .foregroundStyle(e.status == "finished" ? .green : .orange).font(.system(size: compact ? 11 : 14))
                        VStack(alignment: .leading, spacing: 1) {
                            if !compact { Text("\(e.source) · \(e.status)").font(.system(size: 11.5, weight: .semibold)) }
                            let msg = e.message.isEmpty ? e.status : e.message
                            Text(msg).font(.system(size: compact ? 10.5 : 11)).foregroundStyle(compact ? .primary : .secondary).lineLimit(compact ? 1 : 2)
                        }
                        Spacer(minLength: 2)
                        Text(e.date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                            .font(.system(size: compact ? 9 : 10)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                }
            }
        }
        .animation(Theme.spring, value: m.events.map(\.id))
    }
}
