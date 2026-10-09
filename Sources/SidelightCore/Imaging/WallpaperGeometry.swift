import CoreGraphics

/// Where things on screen are in the desktop picture.
public enum WallpaperGeometry {
    /// The part of a picture `imageSize` pixels big that's behind `rect` when the picture fills `screen`: scaled to
    /// cover it and centered, as macOS's "Fill Screen" does.
    ///
    /// - Parameters:
    ///   - rect: In Cocoa screen coordinates (y grows upwards), like `screen`.
    /// - Returns: In the picture's pixels, with a top-left origin as `CGImage.cropping(to:)` expects.
    public static func crop(of rect: CGRect, onScreen screen: CGRect, imageSize: CGSize) -> CGRect {
        guard screen.width > 0, screen.height > 0 else { return CGRect(origin: .zero, size: imageSize) }
        // Picture pixels per screen point. Covering the screen leaves the other axis overflowing.
        let scale = min(imageSize.width / screen.width, imageSize.height / screen.height)
        let overflow = CGPoint(
            x: (imageSize.width - screen.width * scale) / 2, y: (imageSize.height - screen.height * scale) / 2)
        return CGRect(
            x: overflow.x + (rect.minX - screen.minX) * scale,
            y: overflow.y + (screen.maxY - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }
}
