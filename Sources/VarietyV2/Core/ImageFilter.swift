import AppKit
import Foundation

/// Variety's Filtering tab: decides whether a candidate image is usable at all.
///
/// This is a different thing from `Filter`/`EffectRenderer`, which changes how
/// an image *looks*. Variety uses the word "filter" for both; the separation is
/// kept here because they run at different times — this one before download and
/// before display, the effects one at render time.
struct ImageFilter {

    let settings: Settings

    /// Cheap checks that need only the filename, applied before downloading.
    func passesNameCheck(_ name: String) -> Bool {
        guard settings.nameRegexEnabled, !settings.nameRegex.isEmpty else { return true }
        guard let regex = try? NSRegularExpression(pattern: settings.nameRegex) else {
            // An invalid pattern must not silently reject everything.
            NSLog("VarietyV2: name filter '\(settings.nameRegex)' is not a valid regex; ignoring it")
            return true
        }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return regex.firstMatch(in: name, range: range) != nil
    }

    /// Full checks against the decoded image.
    func passes(imageAt url: URL, screenSize: CGSize) -> Bool {
        guard passesNameCheck(url.lastPathComponent) else { return false }

        // Read dimensions from metadata rather than decoding the whole file —
        // these are multi-megabyte wallpapers and most checks need only the size.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat
        else { return false }

        if settings.useLandscapeEnabled, width < height { return false }

        if settings.minSizeEnabled {
            // Variety expresses this as a percentage of screen dimensions.
            let factor = CGFloat(settings.minSize) / 100
            if width < screenSize.width * factor || height < screenSize.height * factor {
                return false
            }
        }

        let needsPixels = settings.lightnessEnabled || settings.desiredColorEnabled
        guard needsPixels else { return true }

        guard let stats = ImageStatistics.of(url) else { return true }

        if settings.lightnessEnabled {
            // Variety's threshold: mean luminance below/above the midpoint.
            switch settings.lightnessMode {
            case .dark where stats.luminance > 0.5: return false
            case .light where stats.luminance < 0.5: return false
            default: break
            }
        }

        if settings.desiredColorEnabled, let wanted = settings.desiredColor, wanted.count == 3 {
            let target = (r: CGFloat(wanted[0]) / 255,
                          g: CGFloat(wanted[1]) / 255,
                          b: CGFloat(wanted[2]) / 255)
            let distance = sqrt(pow(stats.red - target.r, 2)
                                + pow(stats.green - target.g, 2)
                                + pow(stats.blue - target.b, 2))
            // Roughly a quarter of the diagonal of the RGB cube — generous
            // enough to be useful, tight enough to mean something.
            if distance > 0.45 { return false }
        }

        return true
    }
}

/// Mean colour and luminance of an image, computed from a tiny thumbnail.
///
/// Decoding a 4K wallpaper to average its pixels would be absurd; a 32px
/// thumbnail gives the same answer for these purposes.
struct ImageStatistics {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    var luminance: CGFloat { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

    static func of(_ url: URL) -> ImageStatistics? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 32,
              ] as CFDictionary)
        else { return nil }

        let width = thumb.width, height = thumb.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.draw(thumb, in: CGRect(x: 0, y: 0, width: width, height: height))

        var totals = (r: 0.0, g: 0.0, b: 0.0)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            totals.r += Double(pixels[i])
            totals.g += Double(pixels[i + 1])
            totals.b += Double(pixels[i + 2])
        }
        let count = Double(width * height) * 255
        return ImageStatistics(red: CGFloat(totals.r / count),
                               green: CGFloat(totals.g / count),
                               blue: CGFloat(totals.b / count))
    }
}
