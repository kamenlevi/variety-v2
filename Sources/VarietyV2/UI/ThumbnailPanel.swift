import AppKit

/// Variety's filmstrip of recent wallpapers.
///
/// On Linux this is an undecorated always-on-top window pinned to the desktop
/// edge. That approach does not survive contact with macOS — a desktop-level
/// window has to be fought over with Spaces, Mission Control and Stage Manager,
/// and loses. It is a floating `NSPanel` here instead: summoned from the menu,
/// dismissed with Escape, and well-behaved on every Space.
@MainActor
final class ThumbnailPanel: NSPanel {

    private let rotator: Rotator
    private let scroll = NSScrollView()
    private let strip = NSStackView()

    private let thumbHeight: CGFloat = 110
    private let maxThumbnails = 40

    init(rotator: Rotator) {
        self.rotator = rotator
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: thumbHeight + 32),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)

        title = "Recent Wallpapers"
        isFloatingPanel = true
        hidesOnDeactivate = false
        // Appear on whichever Space is active rather than dragging the user
        // back to the one it was opened on.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false

        strip.orientation = .horizontal
        strip.spacing = 8
        strip.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        scroll.documentView = strip
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        contentView = scroll
    }

    /// Escape closes, matching the rest of macOS's transient panels.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    override var canBecomeKey: Bool { true }

    func present() {
        // Sit near the bottom of the screen containing the pointer, which is
        // roughly where Variety's strip lives.
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main

        if let frame = screen?.visibleFrame {
            setFrame(NSRect(x: frame.midX - 450,
                            y: frame.minY + 40,
                            width: min(900, frame.width - 80),
                            height: thumbHeight + 32),
                     display: true)
        }
        makeKeyAndOrderFront(nil)
    }

    func reload() {
        strip.arrangedSubviews.forEach {
            strip.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        // Favourites first, then recent downloads — the images most worth
        // returning to are the ones the user already kept.
        let files = Array((rotator.favoritesForDisplay() + rotator.recentForDisplay())
            .prefix(maxThumbnails))

        for file in files {
            strip.addArrangedSubview(makeThumbnail(for: file))
        }
    }

    private func makeThumbnail(for file: URL) -> NSView {
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyUpOrDown

        // Thumbnails are decoded at display size rather than full resolution —
        // these are 4K+ wallpapers and decoding forty of them at full size
        // would be pointlessly expensive.
        if let image = Self.thumbnail(of: file, height: thumbHeight) {
            button.image = image
        }

        let target = ClosureMenuItem { [weak self] in
            Task { await self?.rotator.show(file: file) }
        }
        button.target = target
        button.action = #selector(ClosureMenuItem.invoke)
        objc_setAssociatedObject(button, Unmanaged.passUnretained(button).toOpaque(),
                                 target, .OBJC_ASSOCIATION_RETAIN)

        button.toolTip = file.lastPathComponent
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: thumbHeight).isActive = true
        if let size = button.image?.size, size.height > 0 {
            let aspect = size.width / size.height
            button.widthAnchor.constraint(equalToConstant: thumbHeight * aspect).isActive = true
        }
        return button
    }

    private static func thumbnail(of file: URL, height: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: height * 3,   // Retina headroom
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}
