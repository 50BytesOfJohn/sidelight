import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import SidelightCore

/// Applies an ``ImageEffect`` to a background bitmap. It runs once per image, size and setting, and the result is a
/// static bitmap, so an effect costs nothing while the panel sits idle.
enum ImageEffectRenderer {
    /// - Parameter pixelsPerPoint: The bitmap's pixels per point on screen, which ``ImageEffect/size`` is scaled by.
    static func apply(
        _ effect: ImageEffect, to image: CGImage, pixelsPerPoint: CGFloat, context: CIContext
    ) -> CGImage? {
        let cell = max(1, CGFloat(effect.size) * pixelsPerPoint)
        let input = CIImage(cgImage: image)
        switch effect.kind {
        case .none:
            return image
        case .pixelate:
            let filter = CIFilter.pixellate()
            filter.inputImage = input.clampedToExtent()
            filter.center = .zero
            filter.scale = Float(cell)
            return render(filter.outputImage, extent: input.extent, context: context)
        case .halftone:
            let dots = CIFilter.dotScreen()
            dots.inputImage = input.clampedToExtent()
            dots.center = .zero
            dots.angle = .pi / 4
            dots.width = Float(cell)
            dots.sharpness = 0.7
            return render(twoTone(dots.outputImage, effect), extent: input.extent, context: context)
        case .posterize:
            let filter = CIFilter.colorPosterize()
            filter.inputImage = input
            filter.levels = Float(effect.levels)
            return render(filter.outputImage, extent: input.extent, context: context)
        case .duotone:
            return render(twoTone(input, effect), extent: input.extent, context: context)
        case .dither:
            return dithered(image, cell: cell, effect: effect)
        case .ascii:
            return ascii(image, cell: cell, effect: effect)
        }
    }

    /// Dark parts in `shadows`, light parts in `highlights`, and a gradient between them.
    private static func twoTone(_ image: CIImage?, _ effect: ImageEffect) -> CIImage? {
        let filter = CIFilter.falseColor()
        filter.inputImage = image
        filter.color0 = CIColor(effect.shadows)
        filter.color1 = CIColor(effect.highlights)
        return filter.outputImage
    }

    private static func render(_ image: CIImage?, extent: CGRect, context: CIContext) -> CGImage? {
        image.flatMap { context.createCGImage($0.cropped(to: extent), from: extent) }
    }

    // MARK: Ordered dither

    /// Each `cell`-sized square becomes one of the two colors by comparing its brightness with the Bayer matrix.
    private static func dithered(_ image: CGImage, cell: CGFloat, effect: ImageEffect) -> CGImage? {
        guard let grid = BrightnessGrid(image, cellWidth: cell, cellHeight: cell) else { return nil }
        let shadows = Pixel(effect.shadows)
        let highlights = Pixel(effect.highlights)
        var pixels = [Pixel](repeating: shadows, count: grid.columns * grid.rows)
        for y in 0..<grid.rows {
            for x in 0..<grid.columns where ImageEffectPatterns.isLight(brightness: grid[x, y], x: x, y: y) {
                pixels[y * grid.columns + x] = highlights
            }
        }
        guard let small = bitmap(pixels, width: grid.columns, height: grid.rows) else { return nil }
        // Scaled back up without smoothing, so every cell keeps hard edges.
        return draw(small, width: image.width, height: image.height, interpolation: .none)
    }

    // MARK: ASCII

    /// Each cell becomes a monospaced character whose density follows the cell's brightness, drawn in `highlights`
    /// on `shadows`. Cells are twice as tall as wide, like the characters.
    private static func ascii(_ image: CGImage, cell: CGFloat, effect: ImageEffect) -> CGImage? {
        let probe = NSFont.monospacedSystemFont(ofSize: 100, weight: .medium)
        let advance = ("M" as NSString).size(withAttributes: [.font: probe]).width / 100
        let font = NSFont.monospacedSystemFont(ofSize: cell / max(advance, 0.1), weight: .medium)
        let rowHeight = cell * 2
        guard let grid = BrightnessGrid(image, cellWidth: cell, cellHeight: rowHeight),
            let context = bitmapContext(width: image.width, height: image.height)
        else { return nil }

        context.setFillColor(.opaque(effect.shadows))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(cgColor: .opaque(effect.highlights)) ?? .white,
        ]
        // Center the glyphs vertically in their row.
        let baselineOffset = (rowHeight - (font.ascender - font.descender)) / 2 - font.descender
        for row in 0..<grid.rows {
            let text = String((0..<grid.columns).map { ImageEffectPatterns.asciiCharacter(brightness: grid[$0, row]) })
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            // Rows run top to bottom; the context's origin is at the bottom.
            context.textPosition = CGPoint(
                x: 0, y: CGFloat(image.height) - CGFloat(row + 1) * rowHeight + baselineOffset)
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }

    // MARK: Bitmaps

    /// RGBA, 8 bits per channel.
    private struct Pixel {
        var red, green, blue, alpha: UInt8

        init(_ color: RGBAColor) {
            red = UInt8((color.red * 255).rounded())
            green = UInt8((color.green * 255).rounded())
            blue = UInt8((color.blue * 255).rounded())
            alpha = 255
        }
    }

    /// The image's brightness averaged over a grid of cells and stretched to the full range, row 0 at the top.
    private struct BrightnessGrid {
        let columns: Int
        let rows: Int
        private let values: [Double]

        init?(_ image: CGImage, cellWidth: CGFloat, cellHeight: CGFloat) {
            columns = max(1, Int((CGFloat(image.width) / cellWidth).rounded(.up)))
            rows = max(1, Int((CGFloat(image.height) / cellHeight).rounded(.up)))
            guard let small = ImageEffectRenderer.draw(image, width: columns, height: rows, interpolation: .high),
                let data = small.dataProvider?.data, let bytes = CFDataGetBytePtr(data)
            else { return nil }
            let bytesPerRow = small.bytesPerRow
            var values: [Double] = []
            values.reserveCapacity(columns * rows)
            for y in 0..<rows {
                for x in 0..<columns {
                    let pixel = bytes + y * bytesPerRow + x * 4
                    values.append(
                        ImageEffectPatterns.brightness(
                            red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255))
                }
            }
            self.values = ImageEffectPatterns.stretched(values)
        }

        subscript(x: Int, y: Int) -> Double { values[y * columns + x] }
    }

    private static func bitmap(_ pixels: [Pixel], width: Int, height: Int) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func bitmapContext(width: Int, height: Int) -> CGContext? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    /// `image` redrawn at `width` × `height` as 8-bit sRGB, which `BrightnessGrid` reads byte by byte.
    fileprivate static func draw(
        _ image: CGImage, width: Int, height: Int, interpolation: CGInterpolationQuality
    ) -> CGImage? {
        guard let context = bitmapContext(width: width, height: height) else { return nil }
        context.interpolationQuality = interpolation
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

extension CIColor {
    fileprivate convenience init(_ color: RGBAColor) {
        self.init(
            red: color.red, green: color.green, blue: color.blue, alpha: 1,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    }
}

extension CGColor {
    /// Opaque: effects draw a solid image.
    fileprivate static func opaque(_ color: RGBAColor) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }
}
