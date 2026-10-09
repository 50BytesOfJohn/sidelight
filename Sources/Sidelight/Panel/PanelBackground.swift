import AppKit
import CoreImage
import ImageIO
import SidelightCore
import SwiftUI

/// The panel's background.
struct PanelBackground: View {
    let background: BackgroundSettings
    let shape: RoundedRectangle
    /// The panel blurs what's behind its window; previews blur what's behind them in their own window.
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    /// Where the panel sits on its screen, so the desktop picture shows exactly the part behind it.
    var cutout: DesktopCutout?

    var body: some View {
        switch background.kind {
        case .none:
            Color.clear
        case .glass:
            Color.clear.glassEffect(background.glass.glass, in: shape)
        case .blur:
            let blur = background.blur
            framed {
                VisualEffectBackground(blur.material, blendingMode: blendingMode, radius: blur.radius)
                Color(blur.tint)
            }
        case .color:
            framed { ColorBackgroundView(color: background.color) }
        case .image:
            framed { BackgroundImageView(image: background.image, cutout: cutout) }
        }
    }

    /// Clipped to the panel's shape with grain and a hairline edge on top.
    private func framed(@ViewBuilder content: () -> some View) -> some View {
        ZStack {
            content()
            GrainOverlay(amount: background.grain)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// The part of the desktop picture behind a panel. With blur, an image background cut out like this looks like
/// frosted glass over the real desktop.
struct DesktopCutout: Equatable {
    /// Whose desktop picture: `nil` for the main display's.
    var displayID: Display.ID?
    /// What the picture fills, scaled to cover it: a display's frame, or a preview's desk.
    var screen: CGRect
    /// What the background covers while the panel fills its strip, in the same coordinates, with y growing upwards.
    /// A fitted panel shows part of it, so resizing never needs a new crop.
    var rect: CGRect
    /// Where a fitted panel's shorter background sits inside `rect`.
    var anchor: Alignment
}

extension GlassBackground {
    var glass: Glass {
        (variant == .clear ? Glass.clear : .regular).tint(tint.amount > 0 ? Color(tint) : nil)
    }
}

/// A solid color or a gradient, optionally drifting.
struct ColorBackgroundView: View {
    let color: ColorBackground

    var body: some View {
        Group {
            switch color.fill {
            case .solid:
                Color(color.color)
            case .gradient where color.isAnimated:
                AnimatedGradient(colors: color.gradient, angle: color.angle)
            case .gradient:
                let (start, end) = UnitPoint.gradientEnds(angle: color.angle)
                LinearGradient(colors: color.gradient.map(Color.init), startPoint: start, endPoint: end)
            }
        }
        .opacity(color.opacity)
    }
}

extension UnitPoint {
    /// Start and end of a linear gradient running at `angle` degrees: 0 left to right, 90 top to bottom.
    static func gradientEnds(angle: Double) -> (start: UnitPoint, end: UnitPoint) {
        let radians = angle * .pi / 180
        let dx = cos(radians) / 2
        let dy = sin(radians) / 2
        return (UnitPoint(x: 0.5 - dx, y: 0.5 - dy), UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
    }
}

/// The gradient as a mesh whose middle slowly drifts. Redraws at 30 fps, so it costs a few percent CPU.
private struct AnimatedGradient: View {
    let colors: [RGBAColor]
    let angle: Double

    var body: some View {
        let meshColors = meshColors
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let dx = Float(sin(time / 6) * 0.25)
            let dy = Float(cos(time / 8) * 0.25)
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5 + dx, 0.5 + dy], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: meshColors
            )
        }
    }

    /// Each mesh point gets the gradient's color at its position along the gradient's direction.
    private var meshColors: [Color] {
        let radians = angle * .pi / 180
        let direction = (x: cos(radians), y: sin(radians))
        let extent = (abs(direction.x) + abs(direction.y)) / 2
        return [0.0, 0.5, 1].flatMap { y in
            [0.0, 0.5, 1].map { x in
                let projection = (x - 0.5) * direction.x + (y - 0.5) * direction.y
                return Color(colors.interpolated(at: extent > 0 ? projection / extent / 2 + 0.5 : 0.5))
            }
        }
    }
}

extension [RGBAColor] {
    /// The color at `position` (0...1) along evenly spaced stops.
    fileprivate func interpolated(at position: Double) -> RGBAColor {
        guard count > 1 else { return first ?? .black }
        let scaled = Swift.min(Swift.max(position, 0), 1) * Double(count - 1)
        let index = Swift.min(Int(scaled), count - 2)
        let fraction = scaled - Double(index)
        let (a, b) = (self[index], self[index + 1])
        return RGBAColor(
            red: a.red + (b.red - a.red) * fraction,
            green: a.green + (b.green - a.green) * fraction,
            blue: a.blue + (b.blue - a.blue) * fraction,
            alpha: a.alpha + (b.alpha - a.alpha) * fraction
        )
    }
}

/// The background image cropped to the view's aspect ratio (or cut out of the desktop picture), blurred, with its
/// effect, then tinted, dimmed and faded to black at the bottom. Without an image it shows a dark gradient.
struct BackgroundImageView: View {
    let image: ImageBackground
    var cutout: DesktopCutout?
    @Environment(DesktopPictures.self) private var desktopPictures

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let url = image.url(desktopPictures: desktopPictures, displayID: cutout?.displayID) {
                    if image.path == nil, let cutout {
                        cutOut(url: url, cutout: cutout, size: proxy.size)
                    } else {
                        focused(url: url, size: proxy.size)
                    }
                } else {
                    PreviewStage()
                }
                Color(image.tint)
                Color.black.opacity(image.dim)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.35),
                        .init(color: .black.opacity(image.fade), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    @ViewBuilder
    private func focused(url: URL, size: CGSize) -> some View {
        if let picture = BackgroundImageLoader.image(
            url: url, crop: .focus(aspectRatio: size.width / max(1, size.height)), pointSize: size, blur: image.blur,
            effect: image.effect)
        {
            Image(nsImage: picture)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            PreviewStage()
        }
    }

    /// The whole strip's crop, pinned to the panel's aligned end, so a fitted panel growing or shrinking reveals
    /// more of the same picture instead of re-cropping it.
    @ViewBuilder
    private func cutOut(url: URL, cutout: DesktopCutout, size: CGSize) -> some View {
        if let picture = BackgroundImageLoader.image(
            url: url, crop: .screen(rect: cutout.rect, screen: cutout.screen), pointSize: cutout.rect.size,
            blur: image.blur, effect: image.effect)
        {
            Image(nsImage: picture)
                .resizable()
                .frame(width: cutout.rect.width, height: cutout.rect.height)
                .frame(width: size.width, height: size.height, alignment: cutout.anchor)
                .clipped()
        } else {
            PreviewStage()
        }
    }
}

extension Appearance {
    /// The color scheme the panel's content uses: light or dark text, or the system's choice.
    ///
    /// - Parameter imageURL: The image background's picture.
    func colorScheme(system: ColorScheme, imageURL: URL?) -> ColorScheme {
        let luminance = background.kind == .image ? imageURL.flatMap(BackgroundImageLoader.luminance) : nil
        switch resolvedText(imageLuminance: luminance) {
        case .automatic: return system
        case .light: return .dark
        case .dark: return .light
        }
    }
}

/// Decodes a background image once per (image, crop, size, blur, effect), crops it, redraws it no larger than
/// needed, blurs it and applies its effect. A huge decoded bitmap is never kept around, and nothing is redrawn
/// while the panel sits idle.
enum BackgroundImageLoader {
    enum Crop: Hashable {
        /// The largest part with this aspect ratio, around a focus point a little above the middle.
        case focus(aspectRatio: CGFloat)
        /// Exactly what's behind `rect` on `screen`, for a desktop picture that fills the screen.
        case screen(rect: CGRect, screen: CGRect)
    }

    /// Everything that decides the bitmap, quantized so slider drags don't re-render on every tiny move.
    private struct Key: Hashable {
        let url: URL
        let crop: Crop
        let pixelWidth: Int
        let pixelHeight: Int
        let blur: Double
        let effect: ImageEffect

        init(url: URL, crop: Crop, pixelSize: CGSize, blur: Double, effect: ImageEffect) {
            self.url = url
            self.crop =
                switch crop {
                case .focus(let aspectRatio): .focus(aspectRatio: (aspectRatio * 100).rounded() / 100)
                case .screen(let rect, let screen): .screen(rect: rect.integral, screen: screen.integral)
                }
            pixelWidth = Int(pixelSize.width.rounded())
            pixelHeight = Int(pixelSize.height.rounded())
            // Steps of 0.5 % for blur and half points for effect sizes; unused parameters don't count.
            self.blur = (blur * 200).rounded() / 200
            var effect = effect
            effect.size = effect.kind.usesSize ? (effect.size * 2).rounded() / 2 : 0
            if !effect.kind.usesLevels { effect.levels = 0 }
            if !effect.kind.usesColors { (effect.shadows, effect.highlights) = (.black, .black) }
            self.effect = effect
        }
    }

    /// The most recently used bitmaps: the panels' plus the Settings previews'.
    private static var cache: [(key: Key, image: NSImage)] = []
    static let cacheLimit = 8
    private static var luminances: [URL: Double] = [:]
    private static let context = CIContext(options: [.cacheIntermediates: false])
    /// Backing pixels per point. Sidelight only runs on Apple Silicon Macs, whose displays are Retina.
    static let pixelsPerPoint: CGFloat = 2

    /// - Parameter pointSize: How big the image is drawn, in points.
    static func image(url: URL, crop: Crop, pointSize: CGSize, blur: Double, effect: ImageEffect) -> NSImage? {
        let pixelSize = CGSize(width: pointSize.width * pixelsPerPoint, height: pointSize.height * pixelsPerPoint)
        let key = Key(url: url, crop: crop, pixelSize: pixelSize, blur: blur, effect: effect)
        if let index = cache.firstIndex(where: { $0.key == key }) {
            let entry = cache.remove(at: index)
            cache.append(entry)
            return entry.image
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let full = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }

        let imageSize = CGSize(width: full.width, height: full.height)
        let cropRect =
            switch key.crop {
            case .focus(let aspectRatio): focusCrop(of: imageSize, aspectRatio: aspectRatio)
            case .screen(let rect, let screen):
                WallpaperGeometry.crop(of: rect, onScreen: screen, imageSize: imageSize)
                    .intersection(CGRect(origin: .zero, size: imageSize))
            }
        guard !cropRect.isEmpty, let cropped = full.cropping(to: cropRect.integral) else { return nil }

        let scale = min(1, pixelSize.width / cropRect.width, pixelSize.height / cropRect.height)
        let outputWidth = max(1, Int(cropRect.width * scale))
        let outputHeight = max(1, Int(cropRect.height * scale))
        guard var output = draw(cropped, width: outputWidth, height: outputHeight) else { return nil }
        if key.blur > 0, let blurred = blurred(output, radius: key.blur * Double(min(outputWidth, outputHeight))) {
            output = blurred
        }
        if key.effect.kind != .none,
            let effected = ImageEffectRenderer.apply(
                key.effect, to: output, pixelsPerPoint: CGFloat(outputWidth) / max(1, pointSize.width),
                context: context)
        {
            output = effected
        }

        let image = NSImage(cgImage: output, size: NSSize(width: outputWidth, height: outputHeight))
        cache.append((key, image))
        if cache.count > cacheLimit { cache.removeFirst() }
        return image
    }

    private static func focusCrop(of size: CGSize, aspectRatio: CGFloat) -> CGRect {
        let focus = CGPoint(x: 0.5, y: 0.4)
        if size.width / size.height > aspectRatio {
            let cropWidth = size.height * aspectRatio
            return CGRect(
                x: max(0, min(size.width - cropWidth, focus.x * size.width - cropWidth / 2)), y: 0,
                width: cropWidth, height: size.height)
        } else {
            let cropHeight = size.width / aspectRatio
            return CGRect(
                x: 0, y: max(0, min(size.height - cropHeight, focus.y * size.height - cropHeight / 2)),
                width: size.width, height: cropHeight)
        }
    }

    /// Average relative luminance of the image, for picking light or dark text.
    static func luminance(of url: URL) -> Double? {
        if let luminance = luminances[url] { return luminance }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 64,
                ] as CFDictionary),
            let pixel = draw(thumbnail, width: 1, height: 1),
            let data = pixel.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else { return nil }
        let average = RGBAColor(
            red: Double(bytes[0]) / 255, green: Double(bytes[1]) / 255, blue: Double(bytes[2]) / 255)
        luminances[url] = average.luminance
        return average.luminance
    }

    private static func draw(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Gaussian blur that doesn't darken the edges: the image is extended outwards first, then cropped back.
    private static func blurred(_ image: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent)
        return context.createCGImage(output, from: input.extent)
    }
}
