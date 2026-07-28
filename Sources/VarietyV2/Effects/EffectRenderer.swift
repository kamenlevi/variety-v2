import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Variety's Effects list, rendered in Core Image.
///
/// Variety hands ImageMagick an argument string per effect and lets it randomly
/// apply one of the enabled ones to each wallpaper. The behaviour is preserved;
/// only the renderer changes. The original arguments are kept on `Filter` so the
/// mapping stays auditable:
///
///     Grayscale          -type Grayscale
///     Heavy blur         -blur 120x40
///     Oil painting       -paint 6
///     Charcoal painting  -charcoal 3
///     Pointilism         -spread 10 -noise 3
///     Pixellate          -scale 3% -scale 3333%
enum EffectRenderer {

    /// Picks one enabled effect at random, matching Variety's behaviour of
    /// applying a single effect rather than stacking them.
    static func randomEnabled(from filters: [Filter]) -> Filter? {
        let enabled = filters.filter(\.enabled)
        guard !enabled.isEmpty else { return nil }
        return enabled.randomElement()
    }

    static func apply(_ filter: Filter, to image: CIImage) -> CIImage {
        // Matched by name rather than by parsing the ImageMagick string: the
        // set is fixed and small, and parsing would imply a generality that
        // does not exist.
        switch filter.name {
        case "Keep original":
            return image

        case "Grayscale":
            let f = CIFilter.photoEffectMono()
            f.inputImage = image
            return f.outputImage ?? image

        case "Heavy blur":
            // -blur 120x40 is a large-radius Gaussian. Clamping first stops the
            // edges going transparent as the kernel samples past the extent.
            let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: 40)
            return blurred.cropped(to: image.extent)

        case "Oil painting":
            // No stock oil-paint filter; crystallise plus a luminance sharpen is
            // the closest approximation to -paint.
            let crystal = CIFilter.crystallize()
            crystal.inputImage = image
            crystal.radius = 12
            crystal.center = CGPoint(x: image.extent.midX, y: image.extent.midY)

            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = crystal.outputImage?.cropped(to: image.extent)
            sharpen.sharpness = 0.6
            return sharpen.outputImage?.cropped(to: image.extent) ?? image

        case "Charcoal painting":
            // Edge detection inverted to dark-on-light, then desaturated:
            // visually close to ImageMagick's -charcoal.
            let edges = CIFilter.edges()
            edges.inputImage = image
            edges.intensity = 4

            let mono = CIFilter.photoEffectMono()
            mono.inputImage = edges.outputImage

            let invert = CIFilter.colorInvert()
            invert.inputImage = mono.outputImage
            return invert.outputImage?.cropped(to: image.extent) ?? image

        case "Pointilism":
            // -spread 10 -noise 3: random local displacement plus noise.
            let pointillize = CIFilter.pointillize()
            pointillize.inputImage = image
            pointillize.radius = 8
            pointillize.center = CGPoint(x: image.extent.midX, y: image.extent.midY)
            return pointillize.outputImage?.cropped(to: image.extent) ?? image

        case "Pixellate":
            // -scale 3% -scale 3333% is a round trip through a tiny bitmap;
            // a pixellate with a proportional scale is the direct equivalent.
            let pixellate = CIFilter.pixellate()
            pixellate.inputImage = image
            pixellate.scale = Float(max(image.extent.width, image.extent.height) * 0.02)
            pixellate.center = CGPoint(x: image.extent.midX, y: image.extent.midY)
            return pixellate.outputImage?.cropped(to: image.extent) ?? image

        default:
            NSLog("VarietyV2: no renderer for effect '\(filter.name)', passing through")
            return image
        }
    }
}
