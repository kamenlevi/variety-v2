import AppKit
import CoreImage
import Foundation

/// Draws the quote and clock overlays onto the wallpaper.
///
/// Variety bakes text into the image file rather than floating a window over
/// the desktop, and that choice ports well: a desktop-level overlay window on
/// macOS has to fight Spaces, Mission Control and Stage Manager, whereas baked
/// pixels simply work. The cost is that a clock tick means re-rendering the
/// whole wallpaper — and, because of the URL cache, writing a new file each
/// time.
enum TextLayer {

    static func compose(quote: Quote, over image: CIImage, size: CGSize) -> CIImage {
        let overlay = render(size: size) { context in
            drawQuote(quote, in: CGRect(origin: .zero, size: size), context: context)
        }
        return overlay.map { $0.composited(over: image) } ?? image
    }

    static func compose(clock date: Date, over image: CIImage, size: CGSize) -> CIImage {
        let overlay = render(size: size) { context in
            drawClock(date, in: CGRect(origin: .zero, size: size), context: context)
        }
        return overlay.map { $0.composited(over: image) } ?? image
    }

    // MARK: - Drawing

    private static func drawQuote(_ quote: Quote, in rect: CGRect, context: NSGraphicsContext) {
        // Quotes sit in the lower-left, inset from the edges, over a soft
        // scrim so they stay readable on a bright photo.
        let margin = rect.width * 0.06
        let maxWidth = min(rect.width * 0.55, 1400)

        let bodyFont = NSFont.systemFont(ofSize: max(28, rect.height * 0.030), weight: .medium)
        let authorFont = NSFont.systemFont(ofSize: max(20, rect.height * 0.020), weight: .regular)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = .init(width: 0, height: -2)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = bodyFont.pointSize * 0.30
        paragraph.alignment = .left

        let body = NSAttributedString(string: "\u{201C}\(quote.text)\u{201D}", attributes: [
            .font: bodyFont,
            .foregroundColor: NSColor.white,
            .shadow: shadow,
            .paragraphStyle: paragraph,
        ])

        let bodyRect = body.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])

        var y = margin
        if let author = quote.author, !author.isEmpty {
            let attributed = NSAttributedString(string: "— \(author)", attributes: [
                .font: authorFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
                .shadow: shadow,
            ])
            attributed.draw(at: CGPoint(x: margin, y: y))
            y += authorFont.pointSize * 2.0
        }

        body.draw(with: CGRect(x: margin, y: y, width: maxWidth, height: bodyRect.height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    private static func drawClock(_ date: Date, in rect: CGRect, context: NSGraphicsContext) {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, d MMMM"

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 20
        shadow.shadowOffset = .init(width: 0, height: -3)

        let timeFont = NSFont.systemFont(ofSize: rect.height * 0.11, weight: .thin)
        let dateFont = NSFont.systemFont(ofSize: rect.height * 0.022, weight: .regular)

        let time = NSAttributedString(string: timeFormatter.string(from: date), attributes: [
            .font: timeFont, .foregroundColor: NSColor.white, .shadow: shadow,
        ])
        let day = NSAttributedString(string: dateFormatter.string(from: date), attributes: [
            .font: dateFont, .foregroundColor: NSColor.white.withAlphaComponent(0.9), .shadow: shadow,
        ])

        // Upper-right, clear of the menu bar and of the lower-left quote.
        let margin = rect.width * 0.06
        let timeSize = time.size()
        let daySize = day.size()

        let timeY = rect.height - margin - timeSize.height
        time.draw(at: CGPoint(x: rect.width - margin - timeSize.width, y: timeY))
        day.draw(at: CGPoint(x: rect.width - margin - daySize.width, y: timeY - daySize.height * 1.2))
    }

    // MARK: - Plumbing

    /// Renders `draw` into a transparent bitmap and hands back a CIImage ready
    /// to composite.
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
