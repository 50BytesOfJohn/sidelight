import SwiftUI

enum NowPlayingWidget: PanelWidget {
    static let meta = WidgetMeta(kind: "nowPlaying", title: "Now playing", icon: "music.note", tint: .pink,
                                 summary: "Track, artist and artwork via media-control.")

    static func content(_ ctx: WidgetContext) -> some View { NowPlayingView(m: ctx.models.np, ctx: ctx) }

    static func settings(_ s: Binding<WidgetSettings>) -> some View {
        Text("No options.").foregroundStyle(.secondary)
    }
}

private struct NowPlayingView: View {
    @ObservedObject var m: NowPlayingModel
    let ctx: WidgetContext

    var body: some View {
        if !m.available {
            if ctx.size == .minimal || ctx.bar { Image(systemName: "music.note.slash").foregroundStyle(.secondary).help("media-control not installed") }
            else { Text("media-control not available.\nbrew install ungive/media-control/media-control").font(.caption).foregroundStyle(.secondary) }
        } else if ctx.bar {
            HStack(spacing: 7) {
                art(24, radius: 5)
                if !m.title.isEmpty {
                    Text(m.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1).frame(maxWidth: 150, alignment: .leading)
                    Image(systemName: m.playing ? "play.fill" : "pause.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
        } else {
            switch ctx.size {
            case .regular:
                if m.title.isEmpty { Text("Nothing playing").font(.callout).foregroundStyle(.secondary) }
                else {
                    HStack(spacing: 12) {
                        art(54, radius: 9).shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            Text(m.artist).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                            Label(m.playing ? "Playing" : "Paused", systemImage: m.playing ? "play.fill" : "pause.fill")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .id(m.title)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                    .animation(Theme.spring, value: m.title)
                }
            case .compact:
                if m.title.isEmpty { Text("Nothing playing").font(.system(size: 11)).foregroundStyle(.secondary) }
                else {
                    HStack(spacing: 8) {
                        art(36, radius: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                            Text(m.artist).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .id(m.title).transition(.opacity)
                    }
                    .animation(Theme.spring, value: m.title)
                }
            case .minimal:
                // artwork thumbnail + tiny play-state glyph
                art(42, radius: 8)
                    .overlay(alignment: .bottomTrailing) {
                        if !m.title.isEmpty {
                            Image(systemName: m.playing ? "play.fill" : "pause.fill")
                                .font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 15, height: 15).background(Circle().fill(.black.opacity(0.7)))
                                .offset(x: 4, y: 4)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .help(m.title.isEmpty ? "Nothing playing" : "\(m.title) — \(m.artist)")
            }
        }
    }

    func art(_ size: CGFloat, radius: CGFloat) -> some View {
        Group {
            if let a = m.artwork, !m.title.isEmpty { Image(nsImage: a).resizable().aspectRatio(contentMode: .fill) }
            else { Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.primary.opacity(0.08)) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
