import AppKit
import CoreImage
import Foundation

/// Renders a crossfade between two wallpapers.
///
/// macOS gives no control over its own wallpaper transition, so the fade is
/// produced by blending the outgoing and incoming images into intermediate
/// files and setting each in turn. Two measured constraints shape this:
///
///   - WallpaperAgent accepts about ten sets per second, so the fade is
///     stepped. Its own crossfade between steps blurs them together, which
///     helps, but this is not a video dissolve.
///   - Every set needs a *new* file path, since the wallpaper is cached by URL.
///     A slow fade therefore writes ten files, which is why frames are rendered
///     at screen resolution rather than the source's.
enum Crossfade {

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Writes the intermediate frames, in display order.
    ///
    /// Returns an empty array when a fade is not wanted or not possible, in
    /// which case the caller just sets the destination image directly.
    static func renderFrames(from previous: URL?,
                             to next: URL,
                             size: CGSize,
                             speed: FadeSpeed,
                             store: GenerationStore) -> [URL] {
        guard speed.steps > 0,
              let previous,
              let fromImage = CIImage(contentsOf: previous),
              let toImage = CIImage(contentsOf: next)
        else { return [] }

        let rect = CGRect(origin: .zero, size: size)
        let from = fitted(fromImage, to: size)
        let to = fitted(toImage, to: size)

        var frames: [URL] = []
        // Endpoints are excluded: the outgoing wallpaper is already on screen,
        // and the caller sets the final image itself.
        for step in 1...speed.steps {
            let alpha = CGFloat(step) / CGFloat(speed.steps + 1)
            guard let blended = blend(from: from, to: to, alpha: alpha, rect: rect),
                  let cgImage = context.createCGImage(blended, from: rect)
            else { continue }

            let url = store.nextURL(ext: "jpg")
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            // Lower quality than a real wallpaper: these are on screen for a
            // tenth of a second each and are pure overhead otherwise.
            guard let data = bitmap.representation(using: .jpeg,
                                                   properties: [.compressionFactor: 0.7]),
                  (try? data.write(to: url, options: .atomic)) != nil
            else { continue }
            frames.append(url)
        }
        return frames
    }

    /// Fades `to` over `from` by `alpha`, both already at the target size.
    private static func blend(from: CIImage, to: CIImage,
                              alpha: CGFloat, rect: CGRect) -> CIImage? {
        // A constant-alpha overlay composited over the outgoing image is the
        // cheapest correct dissolve; CIDissolveTransition would also work but
        // carries a time-based setup this does not need.
        let mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: alpha))
            .cropped(to: rect)

        guard let filter = CIFilter(name: "CIBlendWithAlphaMask") else { return nil }
        filter.setValue(to, forKey: kCIInputImageKey)
        filter.setValue(from, forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask, forKey: kCIInputMaskImageKey)
        return filter.outputImage?.cropped(to: rect)
    }

    /// Scale-to-fill so both endpoints share the frame geometry; a fade between
    /// differently-shaped images would otherwise jump at the start or end.
    private static func fitted(_ image: CIImage, to size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let scale = max(size.width / extent.width, size.height / extent.height)
        let scaled = image.transformed(by: .init(scaleX: scale, y: scale))
        let dx = (scaled.extent.width - size.width) / 2
        let dy = (scaled.extent.height - size.height) / 2

        return scaled
            .transformed(by: .init(translationX: -scaled.extent.origin.x - dx,
                                   y: -scaled.extent.origin.y - dy))
            .cropped(to: CGRect(origin: .zero, size: size))
    }
}
