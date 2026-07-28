import AppKit

/// Variety's strip of thumbnails across the bottom of the screen.
///
/// The Linux original is an undecorated always-on-top window pinned flush to
/// the desktop edge, and that is reproduced here: a borderless panel spanning
/// the full screen width at the bottom, no title bar, no shadow.
///
/// Two macOS-specific accommodations, both necessary rather than cosmetic:
/// the window joins all Spaces so switching desktop does not strand it, and it
/// sits at `.floating` rather than at desktop level — a genuinely desktop-level
/// window on macOS is placed *behind* the Finder's icon layer and would be
/// invisible.
@MainActor
final class FilmstripPanel: NSPanel {

    enum Contents: Equatable { case recent, history, favorites }

    private let rotator: Rotator
    private let scroll = NSScrollView()
    private let strip = NSStackView()

    var contents: Contents = .recent

    private let thumbHeight: CGFloat = 120
    private let maxThumbnails = 60

    init(rotator: Rotator) {
        self.rotator = rotator
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: thumbHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)

        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        hasShadow = false
        backgroundColor = NSColor.black.withAlphaComponent(0.85)
        isOpaque = false

        strip.orientation = .horizontal
        strip.spacing = 2
        strip.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        scroll.documentView = strip
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        contentView = scroll
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    /// Full width, flush to the bottom edge — the original's placement.
    func present() {
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main

        if let frame = screen?.frame {
            setFrame(NSRect(x: frame.minX, y: frame.minY,
                            width: frame.width, height: thumbHeight),
                     display: true)
        }
        makeKeyAndOrderFront(nil)
    }

    func reload() {
        strip.arrangedSubviews.forEach {
            strip.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let files: [URL]
        switch contents {
        case .recent:
            files = rotator.favoritesForDisplay() + rotator.recentForDisplay()
        case .history:
            files = rotator.historyForDisplay
        case .favorites:
            files = rotator.favoritesForDisplay()
        }

        for file in files.prefix(maxThumbnails) {
            strip.addArrangedSubview(makeThumbnail(for: file))
        }
    }

    private func makeThumbnail(for file: URL) -> NSView {
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyUpOrDown
        button.image = Self.thumbnail(of: file, height: thumbHeight)

        let target = ClosureMenuItem { [weak self] in
            Task { await self?.rotator.show(file: file) }
        }
        button.target = target
        button.action = #selector(ClosureMenuItem.invoke)
        // NSButton holds its target weakly, so tie the lifetime to the button.
        objc_setAssociatedObject(button, Unmanaged.passUnretained(button).toOpaque(),
                                 target, .OBJC_ASSOCIATION_RETAIN)

        button.toolTip = file.lastPathComponent
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: thumbHeight).isActive = true
        if let size = button.image?.size, size.height > 0 {
            button.widthAnchor
                .constraint(equalToConstant: thumbHeight * (size.width / size.height))
                .isActive = true
        }
        return button
    }

    /// Decoded at display size — these are 4K+ wallpapers and decoding sixty of
    /// them at full resolution would be pointlessly expensive.
    private static func thumbnail(of file: URL, height: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: height * 3,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}
