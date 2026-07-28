import AppKit
import QuartzCore

/// A smooth crossfade between wallpapers.
///
/// The transition happens in a window sitting at the desktop level: above the
/// wallpaper, but *below* the desktop icon layer, so icons stay in front and it
/// is indistinguishable from the wallpaper itself. Core Animation dissolves
/// inside it at the display's refresh rate, and the real wallpaper is set
/// underneath while it is covered.
///
/// Two things caused a visible blink in an earlier version, both when changes
/// arrived faster than a fade could finish — scrolling the menu bar icon does
/// exactly that, since it permits a change every 0.35 s while a medium fade
/// runs for 1.15 s:
///
///   - windows were built per transition, so each one showed a frame of
///     unrendered black before its layers drew
///   - teardown was unconditional, so the *previous* fade's delayed cleanup
///     tore down the *current* fade's window part-way through
///
/// Windows are therefore created once and reused, and each transition carries a
/// token so only its own cleanup can apply.
@MainActor
final class FadeOverlay {

    private struct Overlay {
        let window: NSWindow
        let base: CALayer
        let incoming: CALayer
    }

    private var overlays: [Overlay] = []
    private var overlayScreens: [NSScreen] = []
    /// Incremented per transition; a cleanup runs only if it still matches.
    private var token = 0

    /// Runs the transition, leaving `next` set as the real wallpaper.
    ///
    /// - Parameter apply: sets the wallpaper for real. Called while the overlay
    ///   covers the screen, so the switch underneath is invisible.
    func crossfade(from previous: URL?,
                   to next: URL,
                   duration: TimeInterval,
                   apply: () throws -> Void) rethrows {
        guard duration > 0,
              let previous,
              let fromImage = Self.decode(previous),
              let toImage = Self.decode(next)
        else {
            try apply()
            return
        }

        rebuildOverlaysIfScreensChanged()
        guard !overlays.isEmpty else {
            try apply()
            return
        }

        token &+= 1
        let thisToken = token

        for overlay in overlays {
            // No implicit animation on the content swap: the layers must be
            // showing the outgoing image *before* the window appears, or the
            // first frame is a cross-dissolve from whatever was there last.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlay.base.contents = fromImage
            overlay.incoming.contents = toImage
            overlay.incoming.opacity = 0
            overlay.incoming.removeAnimation(forKey: "crossfade")
            CATransaction.commit()

            if !overlay.window.isVisible { overlay.window.orderFront(nil) }
        }

        do {
            try apply()
        } catch {
            hide(ifToken: thisToken)
            throw error
        }

        for overlay in overlays {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            overlay.incoming.add(fade, forKey: "crossfade")
            overlay.incoming.opacity = 1
        }

        // Linger past the animation so the system's own wallpaper crossfade —
        // which is running underneath, and takes roughly half a second — has
        // finished before the cover is removed. Too short and the removal
        // reveals a transition still in progress, which reads as a blink.
        let linger = duration + 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + linger) { [weak self] in
            self?.hide(ifToken: thisToken)
        }
    }

    /// Hides only if no newer transition has started since.
    private func hide(ifToken expected: Int) {
        guard token == expected else { return }
        overlays.forEach { $0.window.orderOut(nil) }
    }

    // MARK: - Overlay windows

    private func rebuildOverlaysIfScreensChanged() {
        let screens = NSScreen.screens
        let unchanged = screens.count == overlayScreens.count
            && zip(screens, overlayScreens).allSatisfy { $0.frame == $1.frame }
        guard !unchanged else { return }

        overlays.forEach { $0.window.orderOut(nil) }
        overlays = screens.map(makeOverlay(on:))
        overlayScreens = screens
    }

    private func makeOverlay(on screen: NSScreen) -> Overlay {
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
        base.contentsGravity = .resizeAspectFill
        base.masksToBounds = true
        base.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        let incoming = CALayer()
        incoming.frame = host.bounds
        incoming.contentsGravity = .resizeAspectFill
        incoming.masksToBounds = true
        incoming.opacity = 0
        incoming.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        base.addSublayer(incoming)
        host.layer?.addSublayer(base)
        window.contentView = host

        return Overlay(window: window, base: base, incoming: incoming)
    }

    /// Decoded once at screen size. Full-resolution wallpapers would stutter the
    /// first animation frame while Core Animation uploads them.
    private static func decode(_ url: URL) -> CGImage? {
        let size = ScreenGeometry.largestPixelSize
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
        ] as CFDictionary)
    }
}
