import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let nowPlaying = WidgetMetadata(
        title: "Now playing",
        systemImage: "music.note",
        tint: .pink,
        summary: "Track, artist and artwork via media-control."
    )
}

struct NowPlayingWidgetView: View {
    let layout: WidgetLayout
    @Environment(NowPlayingService.self) private var nowPlaying

    private var playStateSymbol: String { nowPlaying.state.isPlaying ? "play.fill" : "pause.fill" }

    var body: some View {
        if nowPlaying.availability != .available {
            unavailable
        } else {
            switch layout {
            case .regular: regular
            case .compact: compact
            case .minimal: minimal
            case .bar: bar
            }
        }
    }

    @ViewBuilder
    private var unavailable: some View {
        if layout.isGlanceable {
            Image(systemName: "music.note.slash").foregroundStyle(.secondary).help("media-control is not available")
        } else {
            Text("media-control not available.\nbrew install ungive/media-control/media-control")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var regular: some View {
        if !nowPlaying.state.hasTrack {
            Text("Nothing playing").font(.callout).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 12) {
                artwork(size: 54, cornerRadius: 9).shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(nowPlaying.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text(nowPlaying.artist).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    Label(nowPlaying.state.isPlaying ? "Playing" : "Paused", systemImage: playStateSymbol)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .id(nowPlaying.title)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            .animation(Motion.gentle, value: nowPlaying.title)
        }
    }

    @ViewBuilder
    private var compact: some View {
        if !nowPlaying.state.hasTrack {
            Text("Nothing playing").font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                artwork(size: 36, cornerRadius: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(nowPlaying.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Text(nowPlaying.artist).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                .id(nowPlaying.title)
                .transition(.opacity)
            }
            .animation(Motion.gentle, value: nowPlaying.title)
        }
    }

    private var minimal: some View {
        artwork(size: 42, cornerRadius: 8)
            .overlay(alignment: .bottomTrailing) {
                if nowPlaying.state.hasTrack {
                    Image(systemName: playStateSymbol)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(.black.opacity(0.7)))
                        .offset(x: 4, y: 4)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .help(nowPlaying.state.hasTrack ? "\(nowPlaying.title) — \(nowPlaying.artist)" : "Nothing playing")
    }

    private var bar: some View {
        HStack(spacing: 7) {
            artwork(size: 24, cornerRadius: 5)
            if nowPlaying.state.hasTrack {
                Text(nowPlaying.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
                Image(systemName: playStateSymbol).font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
    }

    private func artwork(size: CGFloat, cornerRadius: CGFloat) -> some View {
        Group {
            if let image = nowPlaying.artwork, nowPlaying.state.hasTrack {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.08))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
