import AppKit
import CoreImage
import Foundation

/// Draws the quote and clock overlays onto the wallpaper.
///
/// Variety bakes text into the image rather than floating a desktop window, and
/// that choice ports well — a desktop-level window on macOS has to fight Spaces,
/// Mission Control and Stage Manager. The cost is that a clock tick re-renders
/// the whole wallpaper, and (because of the URL cache) writes a new file.
enum TextLayer {

    static func compose(quote: Quote, over image: CIImage, size: CGSize, settings: Settings) -> CIImage {
        let overlay = render(size: size) { _ in
            drawQuote(quote, in: CGRect(origin: .zero, size: size), settings: settings)
        }
        return overlay.map { $0.composited(over: image) } ?? image
    }

    static func compose(clock date: Date, over image: CIImage, size: CGSize, settings: Settings) -> CIImage {
        let overlay = render(size: size) { _ in
            drawClock(date, in: CGRect(origin: .zero, size: size), settings: settings)
        }
        return overlay.map { $0.composited(over: image) } ?? image
    }

    // MARK: - Quote

    /// Placement follows Variety's three sliders: `quotes_width` as a
    /// percentage of screen width, and `quotes_hpos` / `quotes_vpos` as
    /// percentages positioning the text block (0 = left/top, 100 = right/bottom).
    private static func drawQuote(_ quote: Quote, in rect: CGRect, settings: Settings) {
        let font = parseFont(settings.quotesFont, defaultSize: 30, relativeTo: rect)
        let authorFont = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * 0.65) ?? font

        let textColor = color(from: settings.quotesTextColor)
        let blockWidth = rect.width * CGFloat(settings.quotesWidth) / 100

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = font.pointSize * 0.30
        paragraph.alignment = .left

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
        if settings.quotesTextShadow {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
            shadow.shadowBlurRadius = font.pointSize * 0.35
            shadow.shadowOffset = .init(width: 0, height: -2)
            attributes[.shadow] = shadow
        }

        let body = NSAttributedString(string: "\u{201C}\(quote.text)\u{201D}", attributes: attributes)

        var authorAttributes = attributes
        authorAttributes[.font] = authorFont
        authorAttributes[.foregroundColor] = textColor.withAlphaComponent(0.85)
        let author = quote.author.map {
            NSAttributedString(string: "— \($0)", attributes: authorAttributes)
        }

        let bodyBounds = body.boundingRect(
            with: CGSize(width: blockWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let authorHeight = author.map { $0.size().height + font.pointSize * 0.6 } ?? 0
        let blockHeight = bodyBounds.height + authorHeight

        // Sliders are percentages of the free space, so 0 and 100 sit flush
        // against opposite edges with a small inset.
        let inset = rect.width * 0.04
        let freeX = max(0, rect.width - blockWidth - inset * 2)
        let freeY = max(0, rect.height - blockHeight - inset * 2)
        let originX = inset + freeX * CGFloat(settings.quotesHpos) / 100
        // vpos 0 = top, and the coordinate system is bottom-up.
        let originY = inset + freeY * (1 - CGFloat(settings.quotesVpos) / 100)

        // Backdrop behind the text, per quotes_bg_color / quotes_bg_opacity.
        //
        // Sized to the text actually laid out, not to the full quotes-area
        // width: a short quote in a wide area would otherwise sit in a broad
        // empty band.
        if settings.quotesBgOpacity > 0 {
            let pad = font.pointSize * 0.5
            let drawnWidth = min(blockWidth,
                                 max(bodyBounds.width, author?.size().width ?? 0))
            let backdrop = CGRect(x: originX - pad, y: originY - pad,
                                  width: drawnWidth + pad * 2, height: blockHeight + pad * 2)
            let bg = color(from: settings.quotesBgColor)
                .withAlphaComponent(CGFloat(settings.quotesBgOpacity) / 100)
            bg.setFill()
            NSBezierPath(roundedRect: backdrop, xRadius: pad * 0.6, yRadius: pad * 0.6).fill()
        }

        if let author {
            author.draw(at: CGPoint(x: originX, y: originY))
        }
        body.draw(with: CGRect(x: originX, y: originY + authorHeight,
                               width: blockWidth, height: bodyBounds.height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    // MARK: - Clock

    private static func drawClock(_ date: Date, in rect: CGRect, settings: Settings) {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = settings.clockTimeFormat
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = settings.clockDateFormat

        let timeFont = parseFont(settings.clockFont, defaultSize: 70, relativeTo: rect)
        let dateFont = parseFont(settings.clockDateFont, defaultSize: 30, relativeTo: rect)

        // Variety draws the clock twice — a dark copy offset by two pixels, then
        // the white one — which reads as a hard shadow. Reproduced here.
        let shadowColor = NSColor.black.withAlphaComponent(0.27)

        let time = timeFormatter.string(from: date)
        let day = dateFormatter.string(from: date)

        let hOffset = CGFloat(settings.clockHorizontalOffset)
        let vOffset = CGFloat(settings.clockVerticalOffset)

        func draw(_ text: String, font: NSFont, baselineY: CGFloat) {
            let sized: (NSColor) -> NSAttributedString = { colour in
                NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour])
            }
            let width = sized(.white).size().width
            // Variety anchors SouthEast.
            let x = rect.width - hOffset - width
            sized(shadowColor).draw(at: CGPoint(x: x - 2, y: baselineY - 2))
            sized(.white).draw(at: CGPoint(x: x, y: baselineY))
        }

        draw(time, font: timeFont, baselineY: vOffset)
        draw(day, font: dateFont, baselineY: vOffset - dateFont.pointSize * 1.7)
    }

    // MARK: - Fonts

    /// Parses a Pango-style description as used by Variety — "Serif 70",
    /// "Helvetica Bold 40". The size is treated as relative to a 1080p-tall
    /// screen so a setting chosen on one display looks the same on another.
    static func parseFont(_ description: String, defaultSize: CGFloat, relativeTo rect: CGRect) -> NSFont {
        var parts = description.split(separator: " ").map(String.init)
        var size = defaultSize
        if let last = parts.last, let parsed = Double(last) {
            size = CGFloat(parsed)
            parts.removeLast()
        }

        var traits: NSFontDescriptor.SymbolicTraits = []
        for style in ["Bold", "Italic", "Oblique"] where parts.contains(style) {
            if style == "Bold" { traits.insert(.bold) } else { traits.insert(.italic) }
            parts.removeAll { $0 == style }
        }

        let family = parts.joined(separator: " ")
        let scale = rect.height / 1080
        let scaled = max(10, size * scale)

        let resolved: NSFont
        switch family.lowercased() {
        case "", "sans", "sans-serif":
            resolved = NSFont.systemFont(ofSize: scaled)
        case "serif":
            resolved = NSFont(name: "Times New Roman", size: scaled)
                ?? NSFont.systemFont(ofSize: scaled)
        case "monospace", "mono":
            resolved = NSFont.monospacedSystemFont(ofSize: scaled, weight: .regular)
        default:
            resolved = NSFont(name: family, size: scaled) ?? NSFont.systemFont(ofSize: scaled)
        }

        guard !traits.isEmpty else { return resolved }
        let descriptor = resolved.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: scaled) ?? resolved
    }

    private static func color(from rgb: [Int]) -> NSColor {
        guard rgb.count >= 3 else { return .white }
        return NSColor(calibratedRed: CGFloat(rgb[0]) / 255,
                       green: CGFloat(rgb[1]) / 255,
                       blue: CGFloat(rgb[2]) / 255,
                       alpha: 1)
    }

    // MARK: - Plumbing

    private static func render(size: CGSize, _ draw: (NSGraphicsContext) -> Void) -> CIImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(context)
        NSGraphicsContext.restoreGraphicsState()

        return rep.cgImage.map { CIImage(cgImage: $0) }
    }
}
