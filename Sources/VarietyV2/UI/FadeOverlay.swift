import AppKit
import QuartzCore

/// A smooth crossfade between wallpapers.
///
/// The first attempt rendered blended frames and set each as the wallpaper in
/// turn. That is limited by WallpaperAgent, which accepts roughly ten sets per
/// second — visibly stepped, and it was.
///
/// This does the transition in a window instead. The window sits at the
/// desktop level: above the wallpaper, but *below* the desktop icon layer, so
/// icons and everything else stay in front of it and it is indistinguishable
/// from the wallpaper itself. Core Animation cross-dissolves inside it at the
/// display's own refresh rate, and the real wallpaper is set underneath just
/// before the window goes away — so what remains is the actual wallpaper, not
/// a window pretending to be one.
@MainActor
final class FadeOverlay {

    private var windows: [NSWindow] = []

    /// Runs the transition, then leaves `next` set as the real wallpaper.
    ///
    /// - Parameter apply: sets the wallpaper for real. Called while the overlay
    ///   is still covering the screen, so the switch underneath is invisible.
    func crossfade(from previous: URL?,
                   to next: URL,
                   duration: TimeInterval,
                   apply: () throws -> Void) rethrows {
        guard duration > 0,
              let previous,
              let fromImage = Self.decode(previous, fitting: ScreenGeometry.largestPixelSize),
              let toImage = Self.decode(next, fitting: ScreenGeometry.largestPixelSize)
        else {
            try apply()
            return
        }

        for screen in NSScreen.screens {
            windows.append(makeWindow(on: screen, from: fromImage, to: toImage, duration: duration))
        }

        // Swap the real wallpaper immediately: the overlay hides it, and doing
        // it now means the fade ends on the true wallpaper with no second jump.
        do {
            try apply()
        } catch {
            teardown()
            throw error
        }

        // Tear down after the animation, plus a little slack so the wallpaper
        // underneath is certainly in place before the cover is removed.
        let linger = duration + 0.35
        DispatchQueue.main.asyncAfter(deadline: .now() + linger) { [weak self] in
            self?.teardown()
        }
    }

    private func makeWindow(on screen: NSScreen,
                            from: CGImage, to: CGImage,
                            duration: TimeInterval) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame,
                              styleMask: [.borderless],
                              backing: .buffered, defer: false, screen: screen)

        // Below the desktop icons, above the wallpaper. Anything higher would
        // cover the user's icons for the length of the fade.
        window.level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.hasShadow = false
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false

        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true

        let base = CALayer()
        base.frame = host.bounds
        base.contents = from
        base.contentsGravity = .resizeAspectFill
        base.masksToBounds = true

        let incoming = CALayer()
        incoming.frame = host.bounds
        incoming.contents = to
        incoming.contentsGravity = .resizeAspectFill
        incoming.masksToBounds = true
        incoming.opacity = 0

        base.addSublayer(incoming)
        host.layer?.addSublayer(base)
        window.contentView = host

        window.orderFront(nil)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        incoming.add(fade, forKey: "crossfade")
        incoming.opacity = 1

        return window
    }

    private func teardown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    /// Decoded once at screen size. Full-resolution wallpapers would make the
    /// first animation frame stutter while Core Animation uploads them.
    private static func decode(_ url: URL, fitting size: CGSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
        ] as CFDictionary)
    }
}
