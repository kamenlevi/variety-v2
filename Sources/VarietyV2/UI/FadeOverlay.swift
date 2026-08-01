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
/// The overlay is a reconstruction of the wallpaper, and a reconstruction is
/// never pixel-identical to the real thing — so *every* boundary where the
/// cover appears or disappears must be a blend, never a cut. Each hard edge
/// that existed here has, at some point, been a user-visible blink:
///
///   - windows built per transition showed a frame of unrendered black
///   - unconditional teardown let the previous fade's cleanup tear down the
///     current fade mid-animation
///   - `orderOut` at the end cut from cover to real wallpaper (now a dissolve)
///   - `alphaValue = 1` at the start cut from real wallpaper to cover, and,
///     being a direct set, silently lost to any uncover animation still in
///     flight (now an animator blend, which supersedes it)
///
/// Windows are created once and reused, and each transition carries a token so
/// only its own cleanup can apply.
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

    /// How long the cover takes to blend in before anything changes beneath it.
    private static let coverInDuration: TimeInterval = 0.15

    /// Runs the transition, leaving `next` set as the real wallpaper.
    ///
    /// - Parameter apply: sets the wallpaper for real. Called while the overlay
    ///   covers the screen, so the switch underneath is invisible.
    func crossfade(from previous: URL?,
                   to next: URL,
                   duration: TimeInterval,
                   apply: () throws -> Void) async rethrows {
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

            if !overlay.window.isVisible {
                // Enter transparent: the window becomes visible before the
                // render server has necessarily drawn its first frame, and at
                // alpha 0 whatever that frame contains cannot flash.
                overlay.window.alphaValue = 0
                overlay.window.orderFront(nil)
            }
        }

        // Blend the cover in rather than cutting it on.
        //
        // The uncover at the end of a transition is a dissolve, and for the
        // same reason the cover-on must be one too: the cover is a CALayer
        // reconstruction of what WallpaperAgent is showing, and the two never
        // match pixel-perfectly (colour management, decode differences). A
        // hard cut makes that mismatch visible as a blink at the *start* of
        // every change — the end was already blended, the beginning was not.
        //
        // Going through the animator also supersedes any uncover dissolve
        // still in flight from the previous transition. The old code assigned
        // `alphaValue = 1` directly, which does not cancel a running
        // NSAnimationContext animation — the old animation kept driving the
        // alpha back down, so the fresh cover faded away mid-transition and
        // the wallpaper swap underneath happened in plain view.
        //
        // Awaiting completion also replaces the old CATransaction.flush():
        // once this animation has finished, the cover is by definition
        // composited on screen, so the wallpaper swap below is guaranteed to
        // happen under it rather than racing it.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.coverInDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                overlays.forEach { $0.window.animator().alphaValue = 1 }
            }, completionHandler: { done.resume() })
        }

        do {
            try apply()
        } catch {
            hide(ifToken: thisToken)
            throw error
        }

        for overlay in overlays {
            // Actions disabled around the opacity change: assigning `opacity`
            // outside a transaction adds CoreAnimation's own implicit 0.25 s
            // animation on the same key path, which then runs *alongside* the
            // explicit fade below. Two competing animations on one property
            // make the dissolve jump rather than glide.
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            overlay.incoming.add(fade, forKey: "crossfade")
            overlay.incoming.opacity = 1

            CATransaction.commit()
        }

        // The cover comes off only once the wallpaper underneath has actually
        // changed — never on a timer. See `hideWhenWallpaperLands`.
        hideWhenWallpaperLands(expected: next,
                               token: thisToken,
                               fadeEndsAt: Date().addingTimeInterval(duration))
    }

    // MARK: - Teardown

    /// How often the agent's index is consulted while waiting.
    private static let pollInterval: TimeInterval = 0.1
    /// Grace after the new wallpaper is confirmed, covering the system's own
    /// crossfade, which starts when the agent picks the file up (measured at
    /// ~0.3 s to land, ~0.5 s to fade, so it finishes alongside our own).
    ///
    /// Kept short because the uncover is a dissolve rather than a cut: residual
    /// timing error is now blended away instead of snapping, so there is no
    /// reason to pad the wait and make every change feel sluggish.
    private static let settleGrace: TimeInterval = 0.3
    /// Ceiling on the wait. Reached only if the set silently did nothing, in
    /// which case uncovering shows the truth rather than hiding it forever.
    private static let landingTimeout: TimeInterval = 6

    /// Removes the cover once the real desktop is showing `expected`.
    ///
    /// `setDesktopImageURL` returns immediately, but WallpaperAgent reads the
    /// file and repaints on its own schedule — measured anywhere from ~200 ms
    /// to well over a second, depending on image size and what else the machine
    /// is doing.
    ///
    /// This used to be a fixed `duration + 0.6` timer. Whenever the agent was
    /// slower than that guess, the cover lifted while the desktop underneath
    /// was *still the previous wallpaper*: the new image appeared, snapped back
    /// to the old one for a fraction of a second, then changed again when the
    /// agent finally caught up. Polling the agent's own index turns that guess
    /// into an observation.
    ///
    /// The index lagging behind the set — the reason `WallpaperStore` warns
    /// against reading it once, immediately — is precisely what is being waited
    /// out here.
    private func hideWhenWallpaperLands(expected: URL, token thisToken: Int, fadeEndsAt: Date) {
        let target = expected.resolvingSymlinksInPath().standardizedFileURL
        let startedAt = Date()

        func poll() {
            // A newer transition has taken over the overlay; it owns the
            // teardown now and this one must not pull the cover from under it.
            guard token == thisToken else { return }

            let landed = WallpaperStore.currentImageURL()?
                .resolvingSymlinksInPath().standardizedFileURL == target
            let timedOut = Date().timeIntervalSince(startedAt) >= Self.landingTimeout

            guard landed || timedOut else {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollInterval) {
                    MainActor.assumeIsolated { poll() }
                }
                return
            }

            // Never uncover before the crossfade has played out, however fast
            // the agent was — the animation is the point of the overlay.
            let remainingFade = max(0, fadeEndsAt.timeIntervalSinceNow)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + remainingFade + Self.settleGrace
            ) { [weak self] in
                MainActor.assumeIsolated { self?.hide(ifToken: thisToken) }
            }
        }

        poll()
    }

    /// How long the cover takes to dissolve away at the end of a transition.
    private static let uncoverDuration: TimeInterval = 0.35

    /// Dissolves the cover away, rather than cutting to the real wallpaper.
    ///
    /// This used to be a bare `orderOut`, which is an instantaneous reveal and
    /// therefore shows any difference between the cover and the wallpaper
    /// underneath as a snap — the twitch at the end of an otherwise smooth
    /// fade. Differences are expected and mostly unavoidable: the window server
    /// can defer repainting an occluded desktop, so the system's own wallpaper
    /// crossfade may not have run at all until the moment it becomes visible,
    /// and a `CALayer` and WallpaperAgent do not colour-manage identically.
    ///
    /// Blending the last step instead of cutting it makes the whole class of
    /// mismatch invisible, without needing to enumerate them.
    private func hide(ifToken expected: Int) {
        guard token == expected else { return }
        let windows = overlays.map(\.window)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.uncoverDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            windows.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A newer transition may have claimed the overlay mid-dissolve;
                // it has already reset the alpha and is using these windows.
                guard let self, self.token == expected else { return }
                for window in windows {
                    window.orderOut(nil)
                    window.alphaValue = 1
                }
            }
        })
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
        // Deliberately *not* opaque, even though the content is.
        //
        // A full-screen opaque window lets the window server mark the desktop
        // beneath it as occluded and skip repainting it — so WallpaperAgent's
        // own crossfade to the new image would not actually run until the cover
        // came off, surfacing as a twitch at the very end of the transition.
        // Declaring the window non-opaque keeps the wallpaper live underneath,
        // at negligible compositing cost for one static layer.
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false

        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true

        // Layers created by hand default to `contentsScale` 1, regardless of the
        // display. On Retina that resamples a full-resolution wallpaper down to
        // point size, so the cover renders visibly softer than the real
        // wallpaper — and uncovering snaps from soft to sharp, which reads as a
        // blink at the end of an otherwise clean fade.
        let scale = screen.backingScaleFactor

        let base = CALayer()
        base.frame = host.bounds
        base.contentsScale = scale
        base.contentsGravity = .resizeAspectFill
        base.masksToBounds = true
        // The window is non-opaque, so the cover has to supply its own opacity.
        // Aspect-fill leaves no gap for a correctly-sized wallpaper, but a
        // mismatched image would otherwise let the desktop show through.
        base.backgroundColor = CGColor(gray: 0, alpha: 1)
        base.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        let incoming = CALayer()
        incoming.frame = host.bounds
        incoming.contentsScale = scale
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
