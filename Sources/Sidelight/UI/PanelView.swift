import SwiftUI
import AppKit
import ImageIO

struct PanelRoot: View {
    @ObservedObject var store = ConfigStore.shared
    var models: AppModels = .shared

    var body: some View {
        let c = store.config
        let radius: CGFloat = c.position.isBar ? 14 : 22
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            PanelBackground(config: c, shape: shape)
            if c.animatedBG { AnimatedBackground().clipShape(shape).allowsHitTesting(false) }
            content(c).clipShape(shape)
        }
        .padding(c.position.isBar ? 4 : 6)
        .environment(\.colorScheme, (c.mode == .black || c.mode == .image) ? .dark : (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light))
    }

    @ViewBuilder func content(_ c: AppConfig) -> some View {
        let widgets = c.visibleWidgets
        let chrome = Chrome(mode: c.mode, imageCards: c.imageCards, useGlass: c.useGlass)
        if c.position.isBar {
            container(c) {
                HStack(spacing: 6) {
                    ForEach(widgets) { w in
                        WidgetCard(instance: w, ctx: WidgetContext(size: .minimal, bar: true, settings: w.settings), chrome: chrome)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                }
                .padding(4)
                .animation(Theme.layout, value: widgets.map(\.id))
            }
        } else {
            let size = c.size
            let stack = VStack(spacing: size == .minimal ? 6 : (c.mode == .glass ? 8 : 10)) {
                ForEach(Array(widgets.enumerated()), id: \.element.id) { i, w in
                    WidgetCard(instance: w, ctx: WidgetContext(size: size, settings: w.settings), chrome: chrome)
                        .modifier(Entrance(index: i))
                        .transition(.asymmetric(insertion: .scale(scale: 0.9, anchor: .top).combined(with: .opacity), removal: .opacity))
                }
            }
            .padding(size == .minimal ? 5 : (c.mode == .glass ? 12 : 8))
            .animation(Theme.layout, value: widgets.map(\.id))
            .animation(Theme.layout, value: size)
            container(c) { ScrollView(showsIndicators: false) { stack } }
        }
    }

    /// Glass cards share sampling inside a GlassEffectContainer.
    @ViewBuilder func container<V: View>(_ c: AppConfig, @ViewBuilder _ v: () -> V) -> some View {
        if c.useGlass && (c.mode == .cards || c.mode == .image) { GlassEffectContainer(spacing: 10) { v() } }
        else { v() }
    }
}

struct PanelBackground: View {
    let config: AppConfig
    let shape: RoundedRectangle
    var body: some View {
        switch config.mode {
        case .black:
            shape.fill(Color.black).overlay(shape.strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        case .image:
            ImageBackground(path: config.backgroundImage, dim: config.dim, fade: config.fade)
                .clipShape(shape).overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        case .cards:
            Color.clear
        case .glass:
            if config.useGlass { Color.clear.glassEffect(.regular, in: shape) }
            else { VisualEffect().clipShape(shape) }
        }
    }
}

struct AnimatedBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let a = Float(sin(t / 6) * 0.25), b = Float(cos(t / 8) * 0.25)
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.5 + a, 0.5 + b], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1]
            ], colors: [.indigo, .purple, .blue, .teal, .pink, .indigo, .blue, .purple, .cyan]).opacity(0.45)
        }
    }
}

/// Loads a background image once per (path, aspect bucket), crops a slice matching the panel's aspect
/// around a focus point, and redraws it into a bitmap no bigger than needed, so a huge decode isn't kept.
enum PanelImage {
    private static var cache: [String: NSImage] = [:]
    static func load(path: String?, aspect: CGFloat, maxPixels: CGSize) -> NSImage? {
        let key = "\(path ?? "bundled")|\(Int(aspect * 100))"
        if let c = cache[key] { return c }
        let url: URL? = path.map { URL(fileURLWithPath: $0) } ?? Bundle.main.url(forResource: "wallpaper", withExtension: "jpg")
        guard let url, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let W = CGFloat(full.width), H = CGFloat(full.height)
        // focus: bundled wallpaper's subject is ~57 % across, upper third; custom images: center
        let focus = path == nil ? CGPoint(x: 0.57, y: 0.3) : CGPoint(x: 0.5, y: 0.4)
        var crop: CGRect
        if W / H > aspect {   // image wider than panel → crop width
            let cw = H * aspect
            crop = CGRect(x: max(0, min(W - cw, focus.x * W - cw / 2)), y: 0, width: cw, height: H)
        } else {              // image taller → crop height
            let ch = W / aspect
            crop = CGRect(x: 0, y: max(0, min(H - ch, focus.y * H - ch / 2)), width: W, height: ch)
        }
        guard let cropped = full.cropping(to: crop.integral) else { return nil }
        let scale = min(1, maxPixels.width / crop.width, maxPixels.height / crop.height)
        let outW = max(1, Int(crop.width * scale)), outH = max(1, Int(crop.height * scale))
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        guard let small = ctx.makeImage() else { return nil }
        let img = NSImage(cgImage: small, size: NSSize(width: outW, height: outH))
        cache = [key: img]   // keep only the current one
        return img
    }
}

struct ImageBackground: View {
    var path: String?
    var dim: Double
    var fade: Double
    var body: some View {
        GeometryReader { g in
            ZStack {
                if let img = PanelImage.load(path: path, aspect: g.size.width / max(1, g.size.height),
                                             maxPixels: CGSize(width: g.size.width * 2, height: g.size.height * 2)) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: g.size.width, height: g.size.height).clipped()
                }
                Color.black.opacity(dim)
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.35),
                                       .init(color: .black.opacity(fade), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }
}
