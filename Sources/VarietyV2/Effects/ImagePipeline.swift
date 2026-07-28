import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Turns a downloaded image into the file that actually gets set as wallpaper.
///
/// Variety shells out to ImageMagick for this. Here it is Core Image, which is
/// GPU-backed, removes the dependency entirely, and composes the display mode,
/// the quote layer and the clock layer in a single render pass.
///
/// Every render writes to a fresh path from the `GenerationStore` — see
/// `WallpaperSetter` for why reusing a path silently fails.
struct ImagePipeline {

    struct Request {
        var source: URL
        var targetSize: CGSize
        var mode: DisplayMode
        var quote: Quote?
        var clockDate: Date?
        var settings: Settings
    }

    enum PipelineError: Error, CustomStringConvertible {
        case unreadable(URL)
        case renderFailed

        var description: String {
            switch self {
            case let .unreadable(url): return "could not read image at \(url.lastPathComponent)"
            case .renderFailed: return "Core Image render failed"
            }
        }
    }

    /// Shared context — creating one per render is expensive and defeats the
    /// point of using the GPU.
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func render(_ request: Request, to destination: URL) throws {
        guard let input = CIImage(contentsOf: request.source) else {
            throw PipelineError.unreadable(request.source)
        }

        // `.os` means "don't reframe this" — macOS does its own fitting. The
        // canvas therefore stays the source's own size; using the target size
        // here would crop the image to the screen's dimensions instead of
        // leaving it alone.
        let canvas = request.mode == .os
            ? input.extent.size
            : request.targetSize

        var image = fit(input, to: canvas, mode: request.mode)

        // Overlays are positioned relative to the canvas, so they land
        // correctly in either case.
        if let quote = request.quote {
            image = TextLayer.compose(quote: quote, over: image, size: canvas)
        }
        if let date = request.clockDate {
            image = TextLayer.compose(clock: date, over: image, size: canvas)
        }

        // Normalise the origin: a `.os` passthrough keeps the source extent,
        // which is not guaranteed to start at zero.
        let rect = CGRect(origin: image.extent.origin, size: canvas)
        guard let cgImage = context.createCGImage(image, from: rect) else {
            throw PipelineError.renderFailed
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        // JPEG at high quality: a 6K PNG wallpaper is ~40 MB, and with the
        // clock enabled one of those is written every minute.
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            throw PipelineError.renderFailed
        }
        try data.write(to: destination, options: .atomic)
    }

    // MARK: - Display modes

    private static func fit(_ image: CIImage, to size: CGSize, mode: DisplayMode) -> CIImage {
        switch mode {
        case .os:
            // Hand the original through untouched and let macOS scale it.
            return image

        case .zoom:
            return scaleToFill(image, size: size)

        case .fillWithBlack:
            let fitted = scaleToFit(image, size: size)
            let background = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
            return centre(fitted, over: background, size: size)

        case .fillWithBlur:
            // The background is the same image scaled to *fill* and blurred, so
            // the margins pick up its colours instead of going flat black.
            let background = scaleToFill(image, size: size)
                .clampedToExtent()
                .applyingGaussianBlur(sigma: 40)
                .cropped(to: CGRect(origin: .zero, size: size))
            let fitted = scaleToFit(image, size: size)
            return centre(fitted, over: background, size: size)

        case .oilPainting:
            let filled = scaleToFill(image, size: size)
            // No true oil-paint filter ships with Core Image; the crystallise +
            // sharpen pair is the closest stock approximation of Variety's.
            let crystallise = CIFilter.crystallize()
            crystallise.inputImage = filled
            crystallise.radius = 12
            crystallise.center = CGPoint(x: size.width / 2, y: size.height / 2)

            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = crystallise.outputImage?.cropped(to: CGRect(origin: .zero, size: size))
            sharpen.sharpness = 0.6

            return sharpen.outputImage?.cropped(to: CGRect(origin: .zero, size: size))
                ?? filled
        }
    }

    /// Scale so the image covers the target, cropping the overflow — the usual
    /// wallpaper behaviour.
    private static func scaleToFill(_ image: CIImage, size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let scale = max(size.width / extent.width, size.height / extent.height)
        let scaled = image.transformed(by: .init(scaleX: scale, y: scale))

        // Centre the crop rather than taking the top-left corner.
        let dx = (scaled.extent.width - size.width) / 2
        let dy = (scaled.extent.height - size.height) / 2
        return scaled
            .transformed(by: .init(translationX: -scaled.extent.origin.x - dx,
                                   y: -scaled.extent.origin.y - dy))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Scale so the whole image is visible inside the target.
    private static func scaleToFit(_ image: CIImage, size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let scale = min(size.width / extent.width, size.height / extent.height)
        return image.transformed(by: .init(scaleX: scale, y: scale))
    }

    private static func centre(_ foreground: CIImage, over background: CIImage, size: CGSize) -> CIImage {
        let extent = foreground.extent
        let dx = (size.width - extent.width) / 2 - extent.origin.x
        let dy = (size.height - extent.height) / 2 - extent.origin.y

        let positioned = foreground.transformed(by: .init(translationX: dx, y: dy))
        return positioned.composited(over: background).cropped(to: CGRect(origin: .zero, size: size))
    }
}
