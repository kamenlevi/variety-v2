import AppKit
import QuartzCore

/// Variety's fullscreen slideshow, including the slow zoom-and-pan drift.
///
/// Variety's `slideshow_zoom` and `slideshow_pan` together make a Ken Burns
/// effect; both are honoured here as Core Animation transforms on a layer, so
/// the motion is GPU-driven rather than redrawn per frame.
@MainActor
final class SlideshowController: NSObject {

    private let rotator: Rotator
    private var windows: [NSWindow] = []
    private var imageLayers: [CALayer] = []
    private var files: [URL] = []
    private var index = 0
    private var timer: Timer?

    var onStop: (() -> Void)?
    private(set) var isRunning = false

    init(rotator: Rotator) {
        self.rotator = rotator
    }

    // MARK: - Lifecycle

    func start() {
        let settings = rotator.settings
        files = collectFiles(settings: settings)
        guard !files.isEmpty else {
            NSLog("VarietyV2: slideshow has no images to show")
            return
        }

        switch settings.slideshowSortOrder {
        case "Name": files.sort { $0.lastPathComponent < $1.lastPathComponent }
        case "Date":
            files.sort {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
        default: files.shuffle()
        }

        for screen in targetScreens(settings: settings) {
            makeWindow(on: screen, settings: settings)
        }

        isRunning = true
        index = 0
        advance()

        timer = Timer.scheduledTimer(withTimeInterval: settings.slideshowSeconds,
                                     repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        imageLayers = []
        isRunning = false
        onStop?()
    }

    private func collectFiles(settings: Settings) -> [URL] {
        var pool: [URL] = []
        if settings.slideshowFavoritesEnabled { pool += rotator.favoritesForDisplay() }
        if settings.slideshowDownloadsEnabled { pool += rotator.recentForDisplay() }
        if settings.slideshowSourcesEnabled {
            pool += SourceRegistry.activeLocalFiles(settings: settings)
        }
        if settings.slideshowCustomEnabled {
            pool += SourceRegistry.imageFiles(in: settings.expand(settings.slideshowCustomFolder))
        }
        // Deduplicate: the same file can arrive via several of the above.
        var seen = Set<String>()
        return pool.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func targetScreens(settings: Settings) -> [NSScreen] {
        guard settings.slideshowMonitor != "All",
              let number = Int(settings.slideshowMonitor),
              number >= 1, number <= NSScreen.screens.count
        else { return NSScreen.screens }
        return [NSScreen.screens[number - 1]]
    }

    // MARK: - Windows

    private func makeWindow(on screen: NSScreen, settings: Settings) {
        let fullscreen = settings.slideshowMode != "Window"
        let frame = fullscreen ? screen.frame
            : NSRect(x: screen.frame.midX - 640, y: screen.frame.midY - 400, width: 1280, height: 800)

        let window = NSWindow(
            contentRect: frame,
            styleMask: fullscreen ? [.borderless] : [.titled, .closable, .resizable],
            backing: .buffered, defer: false, screen: screen)

        window.title = "Variety Slideshow"
        window.backgroundColor = .black
        window.isOpaque = true
        if fullscreen {
            // Above everything including the menu bar, as a slideshow should be.
            window.level = .screenSaver
            window.collectionBehavior = [.fullScreenAuxiliary, .stationary]
        }

        let host = SlideshowView()
        host.onDismiss = { [weak self] in self?.stop() }
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor

        let imageLayer = CALayer()
        imageLayer.frame = host.bounds
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        host.layer?.addSublayer(imageLayer)

        window.contentView = host
        window.makeKeyAndOrderFront(nil)

        windows.append(window)
        imageLayers.append(imageLayer)
    }

    // MARK: - Advancing

    private func advance() {
        guard !files.isEmpty else { return }
        let file = files[index % files.count]
        index += 1

        guard let image = downsampled(file) else { return }
        let settings = rotator.settings

        for layer in imageLayers {
            let fade = CATransition()
            fade.duration = settings.slideshowFade
            fade.type = .fade
            layer.add(fade, forKey: "contents")
            layer.contents = image

            applyKenBurns(to: layer, settings: settings)
        }
    }

    /// Zoom and pan run for the full dwell time so the motion never stalls
    /// before the next image arrives.
    private func applyKenBurns(to layer: CALayer, settings: Settings) {
        layer.removeAnimation(forKey: "kenburns")
        guard settings.slideshowZoom > 0 || settings.slideshowPan > 0 else {
            layer.transform = CATransform3DIdentity
            return
        }

        let zoom = 1 + settings.slideshowZoom
        // Pan is a fraction of the layer's size, in a random direction so
        // consecutive images do not drift identically.
        let angle = Double.random(in: 0..<(2 * .pi))
        let distance = settings.slideshowPan * layer.bounds.width
        let dx = cos(angle) * distance
        let dy = sin(angle) * distance

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = CATransform3DIdentity
        var end = CATransform3DMakeScale(zoom, zoom, 1)
        end = CATransform3DTranslate(end, dx, dy, 0)
        animation.toValue = end
        animation.duration = settings.slideshowSeconds
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(animation, forKey: "kenburns")
    }

    /// Decode at roughly screen size. A slideshow of 6000px originals would
    /// churn hundreds of megabytes per image for no visible gain.
    private func downsampled(_ file: URL) -> CGImage? {
        let maxPixel = (NSScreen.main?.frame.width ?? 2560)
            * (NSScreen.main?.backingScaleFactor ?? 2)
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }
}

/// Content view that dismisses on Escape, click, or any key — the behaviour
/// expected of a fullscreen slideshow.
private final class SlideshowView: NSView {
    var onDismiss: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { onDismiss?() }
    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}
