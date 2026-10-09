import AppKit
import SwiftUI

/// Static film-grain noise. Drawn from one small tile generated once, so it costs nothing while idle.
struct GrainOverlay: View {
    var amount: Double

    var body: some View {
        if amount > 0, let tile = Self.tile {
            Image(nsImage: tile)
                .resizable(resizingMode: .tile)
                .blendMode(.overlay)
                .opacity(amount)
                .allowsHitTesting(false)
        }
    }

    /// 128 × 128 points of random gray, at 2× so each grain is one physical pixel on a Retina display.
    private static let tile: NSImage? = {
        let size = 256
        var generator = SystemRandomNumberGenerator()
        let pixels = Data((0..<(size * size)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        guard let provider = CGDataProvider(data: pixels as CFData),
            let image = CGImage(
                width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: size / 2, height: size / 2))
    }()
}
