import AppKit
import Foundation

/// The screen the wallpaper has to fit, and the rules that follow from it.
///
/// Variety asks the image services for screen-appropriate sizes rather than
/// downloading whatever comes back and discarding most of it — Unsplash gets
/// `&w=` computed from the display width, Wallhaven gets `atleast=WxH`. That
/// happens unconditionally, independently of the user's minimum-size filter,
/// and it is the reason its downloads generally fit the screen.
///
/// Sizes are in backing pixels, matching Variety's `hidpi_scaled=True`: on a
/// Retina display a 1512-point-wide screen wants 3024-pixel-wide wallpaper.
enum ScreenGeometry {

    /// The primary display, in real pixels.
    static var primaryPixelSize: CGSize {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return CGSize(width: 2560, height: 1600)
        }
        let scale = screen.backingScaleFactor
        return CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
    }

    /// The largest attached display — what wallpapers are rendered at, so one
    /// image looks sharp on every screen.
    static var largestPixelSize: CGSize {
        let sizes = NSScreen.screens.map { screen -> CGSize in
            let scale = screen.backingScaleFactor
            return CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        }
        return sizes.max { $0.width * $0.height < $1.width * $1.height }
            ?? CGSize(width: 2560, height: 1600)
    }

    static var aspectRatio: CGFloat {
        let size = primaryPixelSize
        return size.height > 0 ? size.width / size.height : 16.0 / 10.0
    }

    /// What to ask a service for. Variety uses `max(1980, width * 1.2)` — the
    /// headroom means an image still fills the screen after cropping to a
    /// different aspect ratio.
    static var requestWidth: Int {
        max(1980, Int(primaryPixelSize.width * 1.2))
    }

    static var requestHeight: Int {
        max(1080, Int(primaryPixelSize.height * 1.2))
    }

    /// Variety's `size_ok`: applied to the dimensions a service reports, before
    /// anything is downloaded.
    static func sizeOK(width: Int, height: Int, settings: Settings) -> Bool {
        if settings.useLandscapeEnabled, width <= height { return false }

        if settings.minSizeEnabled {
            let screen = primaryPixelSize
            let factor = CGFloat(settings.minSize) / 100
            if CGFloat(width) < screen.width * factor { return false }
            if CGFloat(height) < screen.height * factor { return false }
        }
        return true
    }

    /// How well an image's shape matches the screen's, 0...1, where 1 is exact.
    /// Used to prefer images that will crop well.
    static func aspectMatch(width: Int, height: Int) -> Double {
        guard height > 0 else { return 0 }
        let imageRatio = Double(width) / Double(height)
        let screenRatio = Double(aspectRatio)
        return min(imageRatio, screenRatio) / max(imageRatio, screenRatio)
    }

    /// A human-readable summary for the Preferences window.
    static var description: String {
        let size = primaryPixelSize
        let count = NSScreen.screens.count
        let suffix = count > 1 ? " (\(count) displays; wallpapers rendered for the largest)" : ""
        return "\(Int(size.width))×\(Int(size.height))\(suffix)"
    }
}
