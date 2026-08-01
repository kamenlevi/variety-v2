import AppKit
import QuartzCore

/// A smooth crossfade between wallpapers.
///
/// The transition happens in windows the compositor stacks with the desktop:
/// above the wallpaper, below the things the user interacts with. Core
/// Animation dissolves inside them at the display's refresh rate, and the real
/// wallpaper is set underneath while it is covered.
///
/// Each overlay is two panes, because the desktop is drawn as two surfaces
/// (probed via `CGWindowListCopyWindowInfo`, macOS 26.5):
///
///   - the wallpaper itself, at the bottom of the desktop stack — covered by
///     the *desktop pane*, which sits just below the desktop icon layer
///   - an 83 pt wallpaper-derived strip the window server draws across the top
///     of the screen as the menu bar's backdrop, one level *above* the desktop
///     icons — so a desktop-level fade can never reach it, and it repaints
///     only when WallpaperAgent processes the new wallpaper, ~0.3 s late. The
///     *menu bar pane* covers it from one level higher still, below the menu
///     bar's own text and status items (levels 24/25), so the strip fades in
///     lockstep with the desktop instead of trailing it.
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

    /// One window with an outgoing image and an incoming image layered inside.
    private struct Pane {
        let window: NSWindow
        let base: CALayer
        let incoming: CALayer
    }

    /// The panes covering one screen: the desktop, and the menu bar strip when
    /// the screen has one.
    private struct Overlay {
        let panes: [Pane]
    }

    private var overlays: [Overlay] = []
    private var overlayScreens: [NSScreen] = []
    /// Incremented per transition; a cleanup runs only if it still matches.
    private var token = 0

    private var allPanes: [Pane] { overlays.flatMap(\.panes) }

    /// How long the cover takes to blend in before anything changes beneath it.
    private static let coverInDuration: TimeInterval = 0.15

    /// The cover's maximum opacity — deliberately just short of 1.
    ///
    /// A fully opaque cover lets the window server mark the wallpaper beneath
    /// as occluded, and it then *defers everything derived from the wallpaper*
    /// until the cover lifts: the agent's own crossfade, and — the visible
    /// symptom — the menu bar tint, which snapped to the new wallpaper only
    /// after the fade had completely finished. `isOpaque = false` on the
    /// window was not enough; occlusion is judged from the composited pixels,
    /// and ours covered everything at alpha 1. At 98.5% the leak-through is
    /// imperceptible, but the wallpaper stays live underneath, so the menu bar
    /// transitions on its normal schedule, during the fade instead of after it.
    private static let coverAlpha: CGFloat = 0.985

    /// How far ahead of its visible moment a wallpaper set is issued, to absorb
    /// the agent's processing latency (measured ~0.25 s).
    private static let agentLead: TimeInterval = 0.25

    /// Runs the transition, leaving `next` set as the real wallpaper.
    ///
    /// - Parameters:
    ///   - stepFile: hands back a fresh never-used path for an intermediate
    ///     blended wallpaper (paths are cached by the agent, so reuse is a
    ///     silent no-op).
    ///   - applyFile: sets a file as the real wallpaper, logging rather than
    ///     throwing — sets also happen mid-transition, long after the caller
    ///     has moved on.
    func crossfade(from previous: URL?,
                   to next: URL,
                   duration: TimeInterval,
                   stepFile: @escaping () -> URL,
                   applyFile: @escaping (URL) -> Void) async {
        guard duration > 0,
              let previous,
              let fromImage = Self.decode(previous),
              let toImage = Self.decode(next)
        else {
            applyFile(next)
            return
        }

        rebuildOverlaysIfScreensChanged()
        guard !overlays.isEmpty else {
            applyFile(next)
            return
        }

        token &+= 1
        let thisToken = token

        for pane in allPanes {
            // No implicit animation on the content swap: the layers must be
            // showing the outgoing image *before* the window appears, or the
            // first frame is a cross-dissolve from whatever was there last.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pane.base.contents = fromImage
            pane.incoming.contents = toImage
            pane.incoming.opacity = 0
            // Remove ALL animations, not a named one: the step blends carry
            // per-fraction keys, and one is still in flight whenever a change
            // supersedes the previous transition's tail. Left attached, it
            // keeps driving the freshly-swapped layers with the *previous*
            // wallpaper's fractions — the old image ghosting into the new
            // fade, then snapping when the stale animation expires.
            pane.incoming.removeAllAnimations()
            pane.base.removeAllAnimations()
            CATransaction.commit()

            if !pane.window.isVisible {
                // Enter transparent: the window becomes visible before the
                // render server has necessarily drawn its first frame, and at
                // alpha 0 whatever that frame contains cannot flash.
                pane.window.alphaValue = 0
                pane.window.orderFront(nil)
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
        // still in flight from the previous transition; a direct assignment
        // would not, and the old animation would keep driving the alpha down.
        //
        // Awaiting completion guarantees the cover is composited on screen, so
        // the wallpaper swap below happens under it rather than racing it.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.coverInDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.allPanes.forEach { $0.window.animator().alphaValue = Self.coverAlpha }
            }, completionHandler: { done.resume() })
        }

        // Run the desktop and the real wallpaper through the SAME transition,
        // on the SAME clock.
        //
        // The overlay can only animate the desktop; the menu bar's background
        // is a derivation of the real wallpaper that the window server draws
        // above anything coverable, and it updates once per wallpaper set. The
        // two therefore cannot be made one surface — but they can be made to
        // perform identical moves at identical moments, which reads as one.
        //
        // Each step: a blend of old→new is set as the real wallpaper, issued
        // `agentLead` early so it lands on screen at its scheduled moment; at
        // that same moment the overlay blends its own layers to the same
        // fraction. The menu bar tint (fed by the real wallpaper) and the
        // desktop (fed by the overlay) then hold together, move together, and
        // arrive together. An earlier version let the overlay glide smoothly
        // through its own continuous dissolve instead — same endpoints, but
        // between steps the two surfaces visibly drifted apart, which is
        // exactly what it looked like: the menu bar doing something different
        // from the desktop.
        //
        // The blends themselves are invisible (the cover hides the desktop);
        // only their menu bar derivation shows.
        let schedule = Self.stepSchedule(duration: duration)
        // Each overlay step blends rather than snaps, stretched to nearly fill
        // the gap to the next step — back-to-back eased blends read as one
        // continuous motion rather than pulses, which is as smooth as a
        // transition quantised by the agent's set rate can be. Capped at 0.5 s,
        // roughly the agent's own per-set transition, so the overlay and the
        // menu bar tint move over the same span as well as at the same moment.
        let gaps = zip(schedule.dropFirst(), schedule).map { $0.land - $1.land }
        let stepBlend = min(0.5, (gaps.min() ?? duration) * 0.85)
        let fadeEndsAt = Date().addingTimeInterval(duration + stepBlend)

        Task { @MainActor in
            let started = Date()
            var shownFraction: Double = 0

            for step in schedule {
                // Issue the wallpaper set early so it lands on schedule.
                let untilIssue = step.issue - Date().timeIntervalSince(started)
                if untilIssue > 0 { try? await Task.sleep(for: .seconds(untilIssue)) }

                // Superseded: the newer transition owns the wallpaper now, and
                // a stale blend set after its final image would corrupt it.
                guard self.token == thisToken else { return }

                if step.fraction >= 1 {
                    applyFile(next)
                } else {
                    let url = stepFile()
                    let fraction = step.fraction
                    let written = await Task.detached(priority: .userInitiated) {
                        Self.writeBlend(from: fromImage, to: toImage,
                                        fraction: fraction, to: url)
                    }.value
                    if written { applyFile(url) }
                }

                // When it lands, move the overlay with it.
                let untilLand = step.land - Date().timeIntervalSince(started)
                if untilLand > 0 { try? await Task.sleep(for: .seconds(untilLand)) }
                guard self.token == thisToken else { return }

                for pane in self.allPanes {
                    // Actions disabled: an implicit 0.25 s animation on the
                    // same key path would fight the explicit one.
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)

                    let blend = CABasicAnimation(keyPath: "opacity")
                    blend.fromValue = shownFraction
                    blend.toValue = step.fraction
                    blend.duration = stepBlend
                    blend.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    pane.incoming.add(blend, forKey: "crossfade-\(step.fraction)")
                    pane.incoming.opacity = Float(step.fraction)

                    CATransaction.commit()
                }
                shownFraction = step.fraction
            }

            guard self.token == thisToken else { return }
            // The cover comes off only once the wallpaper underneath has
            // actually changed — never on a timer. See `hideWhenWallpaperLands`.
            self.hideWhenWallpaperLands(expected: next,
                                        token: thisToken,
                                        fadeEndsAt: fadeEndsAt)
        }
    }

    // MARK: - Wallpaper steps

    /// The transition's shared clock: when each blend is issued to the agent,
    /// when it lands on screen (and the overlay moves with it), and how far
    /// through the dissolve it is.
    ///
    /// One step per ~0.4 s of fade, capped at four — the agent needs ~0.3 s per
    /// set. The last entry is always fraction 1, the real image.
    ///
    /// The first step lands at ~0.2 s rather than an even `duration / count`
    /// division: with even division a medium fade held the outgoing wallpaper
    /// frozen for 0.4 s before anything moved, which read as the old image
    /// sitting there too long. Movement should begin as soon as the cover is
    /// up; the remaining steps spread evenly to finish exactly at `duration`.
    nonisolated static func stepSchedule(duration: TimeInterval)
        -> [(issue: TimeInterval, land: TimeInterval, fraction: Double)] {
        let count = max(1, min(4, Int((duration / 0.4).rounded())))
        let firstLand = min(0.2, duration / 2)

        return (1...count).map { i in
            let land = count == 1
                ? min(0.3, duration)
                : firstLand + (duration - firstLand) * Double(i - 1) / Double(count - 1)
            return (issue: max(0, land - agentLead),
                    land: land,
                    fraction: Double(i) / Double(count))
        }
    }

    /// Blends `to` over `from` at `fraction` and writes a JPEG.
    ///
    /// Deliberately cheap: these frames are 98.5 % hidden behind the cover and
    /// exist only so the menu bar tint — a heavy blur of the top strip — has
    /// something intermediate to derive from. Fidelity is wasted on them.
    nonisolated private static func writeBlend(from: CGImage, to: CGImage,
                                               fraction: Double, to url: URL) -> Bool {
        let width = to.width, height = to.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { return false }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .medium
        context.draw(from, in: rect)
        context.setAlpha(CGFloat(fraction))
        context.draw(to, in: rect)

        guard let blended = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, "public.jpeg" as CFString, 1, nil)
        else { return false }

        CGImageDestinationAddImage(destination, blended, [
            kCGImageDestinationLossyCompressionQuality: 0.7,
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination)
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
        let windows = allPanes.map(\.window)

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
                    window.alphaValue = Self.coverAlpha
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

        allPanes.forEach { $0.window.orderOut(nil) }
        overlays = screens.map(makeOverlay(on:))
        overlayScreens = screens
    }

    private func makeOverlay(on screen: NSScreen) -> Overlay {
        var panes: [Pane] = []

        // The desktop: below the icon layer, so files on the desktop and
        // widgets stay in front of the fade.
        panes.append(makePane(
            frame: screen.frame,
            imageFrame: NSRect(origin: .zero, size: screen.frame.size),
            level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1),
            // Present in every Space; the desktop exists in all of them.
            behavior: [.canJoinAllSpaces, .stationary, .ignoresCycle],
            scale: screen.backingScaleFactor))

        // The menu bar strip. The window server's wallpaper-derived backdrop
        // for the menu bar sits one level above the desktop icons (probed at
        // desktopIcon+1), so it must be covered from higher still — while
        // staying below the menu bar window itself (level 24), which owns the
        // text, status items and vibrancy that must remain in front.
        //
        // Deliberately *not* .fullScreenAuxiliary: in a full-screen Space the
        // app's content occupies this strip, and a transition there would draw
        // a band of wallpaper over it.
        let stripHeight = screen.frame.maxY - screen.visibleFrame.maxY
        if stripHeight > 0 {
            let strip = NSRect(x: screen.frame.minX,
                               y: screen.frame.maxY - stripHeight,
                               width: screen.frame.width,
                               height: stripHeight)
            // The image layer keeps the full screen's geometry, anchored so its
            // top edge lines up with the strip's: the pane then shows exactly
            // the top sliver of the same aspect-filled image as the desktop
            // pane below it, and the two read as one surface.
            let imageFrame = NSRect(x: 0,
                                    y: stripHeight - screen.frame.height,
                                    width: screen.frame.width,
                                    height: screen.frame.height)
            panes.append(makePane(
                frame: strip,
                imageFrame: imageFrame,
                level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2),
                behavior: [.canJoinAllSpaces, .stationary, .ignoresCycle],
                scale: screen.backingScaleFactor))
        }

        return Overlay(panes: panes)
    }

    private func makePane(frame: NSRect,
                          imageFrame: NSRect,
                          level: NSWindow.Level,
                          behavior: NSWindow.CollectionBehavior,
                          scale: CGFloat) -> Pane {
        let window = NSWindow(contentRect: frame,
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.level = level
        window.collectionBehavior = behavior
        window.ignoresMouseEvents = true
        // Declared non-opaque, but note this flag alone did NOT stop the
        // window server treating the desktop beneath as occluded — occlusion
        // is judged from the composited pixels, and the cover's content is
        // opaque wall to wall. The actual guarantee is `coverAlpha`: the
        // window never quite reaches alpha 1, so the wallpaper (and the menu
        // bar tint derived from it) stays live underneath.
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false

        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        host.layer?.masksToBounds = true

        // Layers created by hand default to `contentsScale` 1, regardless of the
        // display. On Retina that resamples a full-resolution wallpaper down to
        // point size, so the cover renders visibly softer than the real
        // wallpaper — and uncovering snaps from soft to sharp, which reads as a
        // blink at the end of an otherwise clean fade.
        let base = CALayer()
        base.frame = imageFrame
        base.contentsScale = scale
        base.contentsGravity = .resizeAspectFill
        base.masksToBounds = true
        // The window is non-opaque, so the cover has to supply its own opacity.
        // Aspect-fill leaves no gap for a correctly-sized wallpaper, but a
        // mismatched image would otherwise let the desktop show through.
        base.backgroundColor = CGColor(gray: 0, alpha: 1)

        let incoming = CALayer()
        incoming.frame = NSRect(origin: .zero, size: imageFrame.size)
        incoming.contentsScale = scale
        incoming.contentsGravity = .resizeAspectFill
        incoming.masksToBounds = true
        incoming.opacity = 0

        base.addSublayer(incoming)
        host.layer?.addSublayer(base)
        window.contentView = host

        return Pane(window: window, base: base, incoming: incoming)
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
