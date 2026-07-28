import AppKit

/// Scrolling over the menu bar icon moves through wallpapers, as Variety's
/// indicator does on Linux.
///
/// `NSStatusItem`'s button does not forward scroll events on its own, so the
/// handler is installed by swapping in a view that overrides `scrollWheel`.
/// The button's own click behaviour is untouched — the view sits behind it and
/// only ever sees scrolls.
@MainActor
final class StatusItemScrollHandler: NSView {

    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    /// Trackpads emit a stream of small deltas for one gesture; firing per
    /// event would skip through a dozen wallpapers from a single flick. Deltas
    /// are accumulated and only trigger on crossing a threshold.
    private var accumulated: CGFloat = 0
    private static let threshold: CGFloat = 3

    /// Rate limit, since even with a threshold a long scroll would queue up
    /// more changes than anyone wants.
    ///
    /// Set from the fade duration rather than fixed: a change requested before
    /// the previous transition has finished animates over it, which flickers.
    private var lastFired = Date.distantPast
    var minimumInterval: TimeInterval = 0.35
    /// Asked before firing, so a slow render throttles the scroll rather than
    /// queueing behind it.
    var isBusy: () -> Bool = { false }

    override func scrollWheel(with event: NSEvent) {
        // Vertical wins when the gesture is mostly vertical; horizontal
        // trackpad swipes work too, which is more natural on a Mac.
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
            ? event.scrollingDeltaY
            : event.scrollingDeltaX

        // A momentum phase is the tail of a flick the user has stopped driving;
        // acting on it makes one gesture keep changing wallpapers after release.
        guard event.momentumPhase == [] else { return }

        accumulated += delta
        guard abs(accumulated) >= Self.threshold else { return }

        let now = Date()
        guard now.timeIntervalSince(lastFired) >= minimumInterval, !isBusy() else {
            accumulated = 0
            return
        }

        // Scroll up / left for the next wallpaper, down / right for the
        // previous — matching the direction Variety's indicator uses.
        if accumulated > 0 { onNext?() } else { onPrevious?() }

        accumulated = 0
        lastFired = now
    }

    /// Attaches to a status item's button, filling it.
    static func install(on button: NSStatusBarButton,
                        next: @escaping () -> Void,
                        previous: @escaping () -> Void) -> StatusItemScrollHandler {
        let handler = StatusItemScrollHandler(frame: button.bounds)
        handler.onNext = next
        handler.onPrevious = previous
        handler.autoresizingMask = [.width, .height]
        // Added at index 0 so the button's image and click handling stay on top.
        button.addSubview(handler, positioned: .below, relativeTo: nil)
        return handler
    }
}
