import AppKit
import ImageIO
import SwiftUI

/// The display's current desktop picture, downsampled, or the preview gradient when there isn't one we can read
/// (e.g. dynamic or aerial wallpapers).
struct Wallpaper: View {
    let display: Display
    @Environment(DesktopPictures.self) private var desktopPictures
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            PreviewStage()
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .task(id: desktopPictures.url(for: display.id)) {
            image = desktopPictures.url(for: display.id).flatMap { WallpaperThumbnails.thumbnail(for: $0) }
        }
    }
}

/// Small decoded copies of desktop pictures, so a 6K wallpaper is never decoded at full size for a thumbnail.
private enum WallpaperThumbnails {
    private static var cache: [URL: NSImage] = [:]
    static let maximumPixelSize = 480

    static func thumbnail(for url: URL) -> NSImage? {
        if let image = cache[url] { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary
            )
        else { return nil }
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        cache[url] = image
        return image
    }
}
